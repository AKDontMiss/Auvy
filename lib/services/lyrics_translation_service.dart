// lib/services/lyrics_translation_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/services/http_pool.dart';

class LyricsTranslationService {
  // Singleton Pattern
  static final LyricsTranslationService _instance = LyricsTranslationService._internal();
  factory LyricsTranslationService() => _instance;
  LyricsTranslationService._internal();

  /// Capped, because this is a singleton AND a day is long.
  ///
  /// Each entry is every translated line of one song — commonly 40 to 100
  /// strings. Nothing ever removed one, and the service lives as long as the
  /// app, so a day of listening with translation on accumulated a few hundred
  /// songs' worth of text that could never be reached again. Every other cache
  /// in this codebase is bounded for exactly this reason; this one was missed.
  ///
  /// Oldest-first eviction: the lyrics being read are the ones just inserted.
  static const int _maxCachedSongs = 60;
  final Map<String, List<String>> _translationCache = {};

  /// The pooled client, so translation traffic is COUNTED.
  ///
  /// This class is a singleton, so its own client was never a leak, but it was
  /// another blind spot in the data tracker, which only sees what goes through
  /// HttpPool. Batch-translating a full set of lyrics is a real request and it
  /// never appeared in Settings. Same fix, same reason, as CatalogApiClient._http
  /// and ArtistMetadataService, and a getter for the same reason: the pool's
  /// client must be resolved per call, never captured.
  http.Client get _client => HttpPool().getClient();

  static const supportedLanguages = {
    'original': 'Original',
    'en': 'English',
    'sv': 'Swedish',
    'fr': 'French',
    'es': 'Spanish',
    'de': 'German',
    'ar': 'Arabic',
    'am': 'Amharic',
    'tr': 'Turkish',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'hi': 'Hindi',
    'id': 'Indonesian',
    'vi': 'Vietnamese',
    'th': 'Thai',
    'nl': 'Dutch',
    'pl': 'Polish',
  };

  /// Translate each lyric line into [targetLang], preserving the line COUNT and
  /// blank lines so the caller can zip translated[i] back onto the original
  /// line's timestamp[i]. Uses Google Translate's free, key-less `gtx` endpoint
  /// (the previous OpenRouter path required a paid API key that was a
  /// placeholder, and this method previously only ever read the cache and
  /// returned null, so translation never actually happened).
  ///
  /// Returns the translated lines, or the originals if translation fully fails
  /// (never null on a real attempt, so the UI still updates).
  Future<List<String>?> translateLyricsBatch(List<String> lyrics, String targetLang) async {
    if (lyrics.isEmpty || targetLang == 'original') return lyrics;

    final cacheKey = '${lyrics.join('\n').hashCode}_$targetLang';
    final cached = _translationCache[cacheKey];
    if (cached != null) return cached;

    final result = List<String>.from(lyrics); // default to original per-line

    // Translate in small concurrent batches: fast enough for a song (~40 lines)
    // without hammering the endpoint into a rate limit.
    const concurrency = 8;
    for (var start = 0; start < lyrics.length; start += concurrency) {
      final end = (start + concurrency) > lyrics.length ? lyrics.length : start + concurrency;
      await Future.wait([
        for (var i = start; i < end; i++)
          _translateLine(lyrics[i], targetLang).then((t) => result[i] = t),
      ]);
    }

    // Only cache if at least one non-blank line actually changed — otherwise the
    // network was blocked and we don't want to pin a useless "translation".
    var anyTranslated = false;
    for (var i = 0; i < lyrics.length; i++) {
      if (lyrics[i].trim().isNotEmpty && result[i] != lyrics[i]) {
        anyTranslated = true;
        break;
      }
    }
    if (anyTranslated) {
      _translationCache[cacheKey] = result;
      while (_translationCache.length > _maxCachedSongs) {
        _translationCache.remove(_translationCache.keys.first);
      }
    }

    return result;
  }

  /// Translate a single line via the free Google Translate endpoint. Blank lines
  /// (lyric gaps) are kept blank to preserve alignment. Falls back to the
  /// original text on any error.
  Future<String> _translateLine(String text, String targetLang) async {
    if (text.trim().isEmpty) return text;
    try {
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single'
        '?client=gtx&sl=auto&tl=$targetLang&dt=t&q=${Uri.encodeComponent(text)}',
      );
      final resp = await _client
          .get(uri, headers: {'User-Agent': 'Mozilla/5.0'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return text;

      // Response shape: [[["translated","original",...], ...], ..., "srcLang"]
      final decoded = jsonDecode(resp.body);
      final chunks = (decoded is List && decoded.isNotEmpty) ? decoded[0] : null;
      if (chunks is! List) return text;

      final sb = StringBuffer();
      for (final c in chunks) {
        if (c is List && c.isNotEmpty && c[0] is String) sb.write(c[0]);
      }
      final out = sb.toString().trim();
      return out.isEmpty ? text : out;
    } catch (_) {
      return text;
    }
  }

  /// Back-compat streaming API (now also key-free): translates via the batch
  /// translator and yields the lines. Kept so any streaming caller still works.
  Stream<String> streamAiTranslation(List<String> lyricsLines, String targetLang) async* {
    final translated = await translateLyricsBatch(lyricsLines, targetLang) ?? lyricsLines;
    for (final line in translated) {
      yield '$line\n';
    }
  }

  void clearCache() => _translationCache.clear();
}
