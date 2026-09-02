import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:auvy/data/lyrics_model.dart';
import 'package:auvy/services/lyrics_service.dart';
import 'package:auvy/services/lyrics_translation_service.dart';
import 'package:auvy/services/podcast_extras_service.dart';
import 'package:auvy/providers/podcast_extras_provider.dart';
import 'player_provider.dart';

// Per-song lyric offset persistence
// The long-press sync nudge used to reset to zero on every track change; a
// song whose LRC timing is off needed re-nudging every single listen. The
// offset is now remembered per song id and restored when that song plays.
const String _lyricOffsetsKey = 'auvy_lyric_offsets';

Future<void> saveLyricOffsetForSong(String songId, Duration offset) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lyricOffsetsKey);
    final Map<String, dynamic> map =
        raw != null ? Map<String, dynamic>.from(jsonDecode(raw)) : {};
    final key = songId.hashCode.toString();
    if (offset == Duration.zero) {
      map.remove(key); // back in sync → no entry needed
    } else {
      map[key] = offset.inMilliseconds;
    }
    // Cap the ledger so years of nudging can't grow it unbounded.
    while (map.length > 300) {
      map.remove(map.keys.first);
    }
    await prefs.setString(_lyricOffsetsKey, jsonEncode(map));
  } catch (_) {}
}

Future<Duration> loadLyricOffsetForSong(String songId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lyricOffsetsKey);
    if (raw == null) return Duration.zero;
    final ms = (jsonDecode(raw) as Map)[songId.hashCode.toString()];
    if (ms is int && ms != 0) return Duration(milliseconds: ms);
    return Duration.zero;
  } catch (_) {
    return Duration.zero;
  }
}

final currentLyricsLanguageProvider = StateProvider<String>((ref) => 'original');
final lyricsTranslationLoadingProvider = StateProvider<bool>((ref) => false);
final translatedLyricsProvider = StateProvider<Map<String, List<String>>>((ref) => {});

/// User-adjustable lyric/transcript shift, set by long-pressing the line that
/// is actually being heard. Podcasts need it because dynamically-inserted ads
/// shift the delivered audio against the feed transcript; music occasionally
/// needs it when an LRC's timing doesn't match the resolved stream version.
/// Positive = highlight lines later. Persisted PER SONG (restored on track
/// change; see saveLyricOffsetForSong/loadLyricOffsetForSong).
final podcastLyricsOffsetProvider = StateProvider<Duration>((ref) => Duration.zero);

final displayedLyricsProvider = Provider.autoDispose<List<LyricLine>?>((ref) {
  final lyricsAsync = ref.watch(lyricsProvider);
  final selectedLang = ref.watch(currentLyricsLanguageProvider);
  final translatedCache = ref.watch(translatedLyricsProvider);
  
  if (lyricsAsync.value == null) return null;

  // ADVANCE LYRICS BY 200ms
  const offset = Duration(milliseconds: 200);
  // Podcast transcript nudge (zero for music — the provider resets per track
  // and the nudge UI only exists on podcast transcripts).
  final podOffset = ref.watch(podcastLyricsOffsetProvider);

  final originalLines = lyricsAsync.value!.lines.map((line) {
    // Prevent negative durations for the very first line
    final newTime = line.startTime + podOffset - offset;
    return LyricLine(
        startTime: newTime > Duration.zero ? newTime : Duration.zero,
        words: line.words);
  }).toList();

  if (selectedLang == 'original') return originalLines;
  
  // If translated, zip the new words back with the newly shifted timestamps
  final translatedWords = translatedCache[selectedLang];
  if (translatedWords != null) {
    return List.generate(originalLines.length, (index) {
      return LyricLine(
        startTime: originalLines[index].startTime,
        words: index < translatedWords.length ? translatedWords[index] : originalLines[index].words,
      );
    });
  }

  return originalLines;
});

final activeLyricIndexProvider = StateProvider<int>((ref) => 0);
final lyricsRefreshTriggerProvider = StateProvider<int>((ref) => 0);

final lyricsProvider = FutureProvider.autoDispose<LyricsData?>((ref) async {
  //  LISTEN for song changes to clear state safely outside the build cycle
  ref.listen<String?>(playerProvider.select((s) => s.currentSong?.id), (prev, next) {
  if (prev != next) {
    ref.read(translatedLyricsProvider.notifier).state = {};
    ref.read(currentLyricsLanguageProvider.notifier).state = 'original';
    ref.read(lyricsTranslationLoadingProvider.notifier).state = false;
    ref.read(podcastLyricsOffsetProvider.notifier).state = Duration.zero;
    // Restore this song's remembered sync nudge (async; guard against the
    // song changing again — or this autoDispose provider dying — meanwhile).
    if (next != null) {
      loadLyricOffsetForSong(next).then((d) {
        if (d == Duration.zero) return;
        try {
          if (ref.read(playerProvider).currentSong?.id == next) {
            ref.read(podcastLyricsOffsetProvider.notifier).state = d;
          }
        } catch (_) {/* provider disposed */}
      });
    }
    // The manual-refetch flag belongs to the song it was pressed on. Left >0 it
    // made EVERY later song fetch with forceRefresh, bypassing the RAM/disk
    // caches for the rest of the session (slow lyrics + flaky "not found"s on
    // songs that were already cached).
    if (ref.read(lyricsRefreshTriggerProvider) != 0) {
      ref.read(lyricsRefreshTriggerProvider.notifier).state = 0;
    }
    LyricsTranslationService().clearCache();
  }
});

  final currentSong = ref.watch(playerProvider.select((state) => state.currentSong));
  final refreshCount = ref.watch(lyricsRefreshTriggerProvider);

  if (currentSong == null) return null;

  // Live radio: no lyrics exist for a station stream — an LRC search on the
  // station name only ever matched some unrelated song.
  if (currentSong.id.startsWith('http') && currentSong.albumTitle != 'Podcast') {
    return null;
  }

  // Podcasts: the "lyrics" are the episode transcript, when the feed ships one
  // (Podcasting 2.0 <podcast:transcript>). Skip the LRC search entirely.
  if (currentSong.albumTitle == 'Podcast') {
    final ep = await ref.watch(currentPodcastEpisodeProvider.future);
    final url = ep?.transcriptUrl ?? '';
    if (url.isEmpty) return null;
    final lines = await PodcastExtrasService().fetchTranscript(url);
    if (lines.isEmpty) return null;
    return LyricsData(
      id: 0,
      trackName: currentSong.title,
      artistName: currentSong.artist,
      albumName: 'Podcast',
      duration: 0,
      instrumental: false,
      plainLyrics: lines.map((l) => l.words).join('\n'),
      syncedLyrics: '',
      lines: lines,
    );
  }

  // Track duration — the strongest signal for picking the RIGHT version of a
  // title among several with the same name.
  //
  // THIS USED TO BE `ref.read`, and that produced wrong lyrics on first play.
  // At the moment a track starts, duration is still 0 (the engine hasn't reported
  // it yet), so the fetch went out with `trackDurationMs: null` and the scorer had
  // nothing to disambiguate with — for a common title like "Warrior" it could
  // settle on a different song entirely. Reopening the app fetched again with a
  // restored duration and got it right, which is exactly the reported
  // "wrong lyrics at first, correct after I reopened the app".
  //
  // Watched in SECONDS on purpose: duration changes 0 → N exactly once per track,
  // so this refetches once when the real length arrives and never again — it is
  // not the position, so this is not a per-tick rebuild. (Seconds rather than
  // milliseconds so a one-off ms correction from the engine can't trigger a
  // second fetch.)
  final durationSec =
      ref.watch(playerProvider.select((s) => s.duration.inSeconds));
  final durationMs = durationSec * 1000;

  final service = LyricsService();
  final lyricsData = await service.getLyrics(
    currentSong.title,
    currentSong.artist,
    album: currentSong.albumTitle,
    songId: currentSong.id,
    forceRefresh: refreshCount > 0,
    trackDurationMs: durationMs > 0 ? durationMs : null,
  );

  return lyricsData;
});

//  Triggers translation on language change
final lyricsLanguageListenerProvider = Provider.autoDispose<void>((ref) {
  final selectedLang = ref.watch(currentLyricsLanguageProvider);
  
  if (selectedLang != 'original') {
    final translatedCache = ref.read(translatedLyricsProvider);
    if (!translatedCache.containsKey(selectedLang)) {
      loadTranslation(ref, selectedLang);
    }
  }
});

Future<void> loadTranslation(Ref ref, String targetLang) async {
  final lyricsAsync = ref.read(lyricsProvider);
  final translatedCache = ref.read(translatedLyricsProvider);
  
  if (translatedCache.containsKey(targetLang)) return;
  if (lyricsAsync.value == null) return;
  
  final originalLines = lyricsAsync.value!.lines.map((l) => l.words).toList();
  ref.read(lyricsTranslationLoadingProvider.notifier).state = true;
  
  try {
    final translationService = LyricsTranslationService();
    final translated = await translationService.translateLyricsBatch(originalLines, targetLang);
    
    if (translated != null) {
      ref.read(translatedLyricsProvider.notifier).update((state) => {
        ...state,
        targetLang: translated,
      });
    }
  } catch (e) {
    print("ERROR: Translation error: $e");
  } finally {
    ref.read(lyricsTranslationLoadingProvider.notifier).state = false;
  }
}