// lib/services/lyrics_translation_service.dart

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:auvy/services/http_pool.dart';

class LyricsTranslationService {
  // Singleton Pattern
  static final LyricsTranslationService _instance = LyricsTranslationService._internal();
  factory LyricsTranslationService() => _instance;
  LyricsTranslationService._internal();

  /// Capped, because this singleton lives as long as the app and each entry holds
  /// every translated line of one song. Oldest first: the lyrics being read are the
  /// ones just added.
  static const int _maxCachedSongs = 60;
  final Map<String, List<String>> _translationCache = {};

  /// In-flight translation promises, keyed by cacheKey. Multiple callers asking
  /// for the same batch/language join the single active Future rather than
  /// hammering the translation endpoint with redundant parallel bursts.
  final Map<String, Future<List<String>?>> _inFlight = {};

  /// Circuit breaker cooldown when encountering HTTP 429 rate limits.
  DateTime? _circuitOpenUntil;

  /// The pooled client, so translation traffic is counted in the data tracker. A
  /// getter because the pool's client must be resolved per call, not captured (see
  /// CatalogApiClient._http).
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

  /// Translates each lyric line into [targetLang], keeping the line count and
  /// blank lines so translated[i] lines up with the original line's timestamp[i].
  /// Uses Google Translate's free, key-less `gtx` endpoint.
  ///
  /// Returns the translated lines, or the originals if translation fails entirely
  /// (never null on a real attempt, so the UI still updates).
  Future<List<String>?> translateLyricsBatch(List<String> lyrics, String targetLang) async {
    if (lyrics.isEmpty || targetLang == 'original') return lyrics;

    final openUntil = _circuitOpenUntil;
    if (openUntil != null) {
      if (DateTime.now().isBefore(openUntil)) {
        print('LyricsTranslation: circuit breaker open until $openUntil (429 cooldown) — returning originals');
        return lyrics;
      } else {
        _circuitOpenUntil = null;
      }
    }

    final cacheKey = '${lyrics.join('\n').hashCode}_$targetLang';
    final cached = _translationCache[cacheKey];
    if (cached != null) return cached;

    final active = _inFlight[cacheKey];
    if (active != null) {
      print('LyricsTranslation: joining in-flight translation for $targetLang (${lyrics.length} lines)');
      return active;
    }

    final future = _translateBatchInternal(lyrics, targetLang, cacheKey);
    _inFlight[cacheKey] = future;
    return future;
  }

  Future<List<String>?> _translateBatchInternal(
      List<String> lyrics, String targetLang, String cacheKey) async {
    try {
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
        print('LyricsTranslation: successfully translated ${lyrics.length} lines into $targetLang');
      } else {
        print('LyricsTranslation: endpoint unreachable or unchanged for $targetLang — using originals');
      }

      return result;
    } finally {
      _inFlight.remove(cacheKey);
    }
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
      if (resp.statusCode == 429) {
        _circuitOpenUntil = DateTime.now().add(const Duration(seconds: 60));
        print('LyricsTranslation: HTTP 429 Too Many Requests — tripping circuit breaker for 60s');
        return text;
      }
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

  void clearCache() {
    _translationCache.clear();
    _inFlight.clear();
    _circuitOpenUntil = null;
    print('LyricsTranslation: cache and in-flight queue cleared');
  }
}
