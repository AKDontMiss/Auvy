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

/// Lazy video→audio matching for list display.
///
/// With audio-only mode on (the default), a music-video row carries a 16:9 video
/// still and the video's title. This resolves each such row to its audio track
/// (square album cover and clean title) in the background and updates the tile in
/// place, so lists show album artwork before anything is played.
///
/// Cost: a row is looked up only when it's actually built on screen (call
/// [conformedForDisplay] from a tile's build), at most once ever (cached in
/// [SearchService.conformToAudioCached]), and the result is shared with the
/// play-time swap. Each lookup is a small metadata search, not an audio download.
///
/// Only the displayed cover and title change. Playback still targets the original
/// row; the play-time swap does the actual audio replacement.
class ConformNotifier extends StateNotifier<Map<String, ConformEntry>> {
  ConformNotifier(this._service) : super(const {});
  final SearchService _service;

  final Set<String> _seen = {}; // ids already requested (dedupe / no-retry)
  final List<Song> _queue = []; // waiting for a free lookup slot
  int _active = 0;
  static const int _maxConcurrent = 4; // keep bursts of searches modest

  /// How long a row may stay blank while its lookup resolves. Hiding the video
  /// thumbnail avoids downloading a cover about to be replaced and a visible swap,
  /// but in long lists lookups queue up ([_maxConcurrent] at a time). Past this
  /// window the original thumbnail is shown and swapped when the lookup lands.
  /// Cached and fast lookups finish well inside it.
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
    // Only on-screen rows start the grace clock. A prefetched row's clock would run
    // out off screen, and it would then flicker from video still to cover when
    // scrolled into view.
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

  // Don't download a cover we're about to replace: a video row's 16:9 still will
  // be replaced by the audio cover once the lookup lands. A blank path makes
  // AuvyImage draw its placeholder (no request), which then crossfades into the
  // real cover. Only while the lookup is inside its grace window (see
  // ConformNotifier._thumbGrace).
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

/// Looks up the next few rows past the one being built. A lookahead following the
/// viewport, not a bulk prefetch (each lookup is a search, and prefetching a
/// whole 60-row playlist fired 60 at once). Six rows is about a screen past the
/// fold, so rows are usually resolved before they appear.
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
