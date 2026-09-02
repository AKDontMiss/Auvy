// lib/services/song_recognition_service.dart
//
// "Shazam-style" song recognition. Same idea as other YouTube Music clients's recognition module
// (MusicRecognitionService.kt + the shazamkit Shazam.kt client). It captures a
// few seconds of microphone audio, resamples it to 16 kHz mono, builds a Shazam
// signature with the pure-Dart [generateAudioFingerprint] and POSTs it to the
// public amp.shazam.com discovery endpoint — no paid fingerprint service or API
// key required.
//
// The recording + fingerprint runs off the UI isolate (via `compute`) so the
// listening animation stays smooth.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import 'package:auvy/logic/recognition/audio_fingerprint.dart';

/// Microphone capture parameters. 44.1 kHz mono is universally supported by
/// Android mics; we resample to 16 kHz, which is what the signature format wants.
const int _recordingSampleRate = 44100;

/// Listening window. 12 s gives the fingerprint enough peaks for a solid match.
const Duration _recordDuration = Duration(seconds: 12);

/// Progressive query checkpoints (seconds of captured audio). We fingerprint +
/// query at each and stop on the first confident match — fast for clear audio,
/// with escalating attempts for harder cases.
const List<int> _checkpointsSec = [4, 7, 10, 12];

/// Phases surfaced to the UI while [SongRecognitionService.recognize] runs.
enum RecognitionPhase { requestingPermission, listening, processing, querying }

/// Result of a recognition attempt.
enum RecognitionState { success, noMatch, error }

class SongRecognitionResult {
  final String trackId;
  final String title;
  final String artist;
  final String? album;
  final String? coverArtUrl;
  final String? coverArtHqUrl;
  final String? genre;
  final String? releaseDate;
  final String? label;
  final String? shazamUrl;
  final String? appleMusicUrl;
  final String? spotifyUrl;
  final String? isrc;
  final String? youtubeVideoId;

  const SongRecognitionResult({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album,
    this.coverArtUrl,
    this.coverArtHqUrl,
    this.genre,
    this.releaseDate,
    this.label,
    this.shazamUrl,
    this.appleMusicUrl,
    this.spotifyUrl,
    this.isrc,
    this.youtubeVideoId,
  });

  /// Best artwork available (HQ preferred).
  String? get bestCoverArt => coverArtHqUrl ?? coverArtUrl;

  /// A query string suitable for feeding Auvy's YouTube Music search.
  String get searchQuery => '$title $artist'.trim();
}

/// A recognition attempt outcome — a small tagged union so the UI can branch
/// cleanly without exceptions for the "expected" no-match path.
class RecognitionOutcome {
  final RecognitionState state;
  final SongRecognitionResult? result;
  final String? message;

  const RecognitionOutcome._(this.state, {this.result, this.message});

  factory RecognitionOutcome.success(SongRecognitionResult r) =>
      RecognitionOutcome._(RecognitionState.success, result: r);
  factory RecognitionOutcome.noMatch([String? message]) =>
      RecognitionOutcome._(RecognitionState.noMatch,
          message: message ?? 'No match found. Try again with clearer audio.');
  factory RecognitionOutcome.error(String message) =>
      RecognitionOutcome._(RecognitionState.error, message: message);

  bool get isSuccess => state == RecognitionState.success;

  /// A real failure, as opposed to a clean "nothing matched". The two deserve
  /// different words in front of the user.
  bool get isError => state == RecognitionState.error;
}

/// Runs on a background isolate: resample 44.1 kHz → 16 kHz then fingerprint.
String _fingerprintIsolate(Uint8List pcm44k) {
  final pcm16k = resamplePcm16(pcm44k, _recordingSampleRate, 16000);
  return generateAudioFingerprint(pcm16k);
}

class SongRecognitionService {
  static const String _tag = 'SongRecognition';

  // ONE CONSISTENT CLIENT STRING — NOT A ROTATION OF SPOOFED ONES.
  //
  // This used to pick at random from five old Dalvik User-Agents, with the stated
  // purpose that requests "don't look like a single bot hammering the endpoint".
  // Alongside it, every query carried a RANDOMISED latitude, longitude and
  // timezone. Both existed to make one client look like many different users.
  //
  // Adopting GPL-3.0 settled the copyright question about this code. It settles
  // nothing about that: deliberately disguising the caller to slip past rate
  // limiting on a service Auvy has no agreement with is evasion, and shipping it
  // while telling users the app is above board would be a lie.
  //
  // A single plausible modern Android string is kept rather than an honest
  // "Auvy/1.0", because the endpoint expects an Android client and rejects what it
  // does not recognise — this is about not being deceptive, not about breaking the
  // feature. If the endpoint rate-limits us, the answer is to accept the limit.
  //
  // Do not reintroduce the rotation or the fake coordinates.
  static const String _userAgent =
      'Dalvik/2.1.0 (Linux; U; Android 13; Pixel 7 Build/TQ3A.230805.001)';

  final AudioRecorder _recorder = AudioRecorder();
  final Random _random = Random();
  bool _cancelled = false;

  /// Whether microphone permission is (already) granted. `AudioRecorder`
  /// requests it if needed when [recognize] starts.
  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Identifies audio that was captured ELSEWHERE — currently the "capture app
  /// audio" mode, which reads this device's playback instead of the microphone.
  ///
  /// Shares the whole query path with [recognize] rather than duplicating it: same
  /// isolate fingerprinting, same Shazam client, same outcome type. The only thing
  /// the two modes disagree about is where the PCM came from, so that's the only
  /// thing that differs here.
  ///
  /// [pcm] must be 16-bit mono little-endian at [_recordingSampleRate]. There's no
  /// progressive-checkpoint loop: a capture arrives complete, so there is nothing
  /// to escalate through — one fingerprint, one query.
  Future<RecognitionOutcome> recognizeFromPcm(
    Uint8List pcm, {
    void Function(RecognitionPhase)? onPhase,
  }) async {
    _cancelled = false;
    try {
      if (pcm.length < _recordingSampleRate) {
        return RecognitionOutcome.error('Not enough audio was captured.');
      }
      onPhase?.call(RecognitionPhase.processing);
      final signature = await compute(_fingerprintIsolate, pcm);
      if (_cancelled) return RecognitionOutcome.error('Cancelled.');

      final sampleDurationMs =
          ((pcm.length ~/ 2) * 1000 / _recordingSampleRate).round();
      onPhase?.call(RecognitionPhase.querying);
      final outcome = await _queryFingerprintService(signature, sampleDurationMs);
      // Same reasoning as in [recognize]: a cancel during the network round-trip
      // must not surface a result afterwards.
      if (_cancelled) return RecognitionOutcome.error('Cancelled.');
      return outcome;
    } catch (e) {
      debugPrint('[$_tag] recognizeFromPcm failed: $e');
      return RecognitionOutcome.error('Recognition failed. Please try again.');
    }
  }

  /// Cancels an in-flight recognition (stops recording early).
  Future<void> cancel() async {
    _cancelled = true;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {}
  }

  /// Progressive recognition: it keeps ONE mic stream open and fingerprints +
  /// queries Shazam at growing checkpoints ([_checkpointsSec]), returning the
  /// instant Shazam is confident. Clear audio matches in ~4 s (fast); hard
  /// audio gets up to 4 escalating attempts on more data (accurate). [onPhase]
  /// reports progress. Never throws on the common paths — returns a
  /// [RecognitionOutcome] describing success / no-match / error.
  Future<RecognitionOutcome> recognize(
      {void Function(RecognitionPhase)? onPhase}) async {
    _cancelled = false;
    StreamSubscription<Uint8List>? sub;

    try {
      onPhase?.call(RecognitionPhase.requestingPermission);
      if (!await _recorder.hasPermission()) {
        return RecognitionOutcome.error('Microphone permission denied.');
      }

      onPhase?.call(RecognitionPhase.listening);
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _recordingSampleRate,
        numChannels: 1,
        // Mic tuning off: we want the raw signal, not voice-optimised audio.
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ));

      final builder = BytesBuilder(copy: true);
      var streamDone = false;
      Object? streamError;
      Completer<void>? waiter;
      var waitTargetBytes = 0;

      void wake() {
        if (waiter != null && !waiter.isCompleted) waiter.complete();
      }

      sub = stream.listen(
        (chunk) {
          builder.add(chunk);
          if (builder.length >= waitTargetBytes) wake();
        },
        onError: (Object e) {
          streamError = e;
          streamDone = true;
          wake();
        },
        onDone: () {
          streamDone = true;
          wake();
        },
        cancelOnError: true,
      );

      var lastOutcome = RecognitionOutcome.noMatch();
      var lastQueryMs = 0;

      for (var i = 0; i < _checkpointsSec.length; i++) {
        if (_cancelled) return RecognitionOutcome.error('Cancelled.');
        final targetBytes =
            _recordingSampleRate * 2 * _checkpointsSec[i]; // 16-bit mono

        // Wait until enough audio has arrived (or the stream ends / stalls).
        if (builder.length < targetBytes && !streamDone) {
          waitTargetBytes = targetBytes;
          waiter = Completer<void>();
          var timedOut = false;
          await waiter.future.timeout(
              _recordDuration + const Duration(seconds: 3),
              // This swallowed the one fact worth knowing.
              //
              // A microphone that delivers nothing lands here and the loop
              // simply carries on with whatever it has, so the visible symptom
              // is a recognition that sits on "Identifying…" and then reports a
              // plain no-match. Nothing distinguished that from genuinely not
              // recognising the song, which is a different problem with a
              // different fix.
              onTimeout: () => timedOut = true);
          if (timedOut) {
            print('WARN: waited for ${targetBytes ~/ 1024}KB of audio and got '
                '${builder.length ~/ 1024}KB — the mic stream stalled; '
                'continuing with a short sample');
          }
          waiter = null;
        }

        if (streamError != null) {
          // The user-facing string stays friendly; the real one is worth
          // recording, because "Microphone error" covers a denied permission,
          // a device already recording, and a codec refusal alike.
          print('WARN: mic stream failed: $streamError');
          return RecognitionOutcome.error('Microphone error. Try again.');
        }
        if (_cancelled) return RecognitionOutcome.error('Cancelled.');

        final snapshot = builder.toBytes();
        if (snapshot.length < _recordingSampleRate * 2) {
          if (streamDone) {
            return RecognitionOutcome.error('Not enough audio was captured.');
          }
          continue; // keep listening
        }

        onPhase?.call(RecognitionPhase.processing);

        final signature = await compute(_fingerprintIsolate, snapshot);
        final sampleDurationMs =
            ((snapshot.length ~/ 2) * 1000 / _recordingSampleRate).round();

        // Space queries ≥1 s apart so escalating attempts don't trip Shazam's
        // rate limiter.
        final since = DateTime.now().millisecondsSinceEpoch - lastQueryMs;
        if (since < 1000) {
          await Future<void>.delayed(Duration(milliseconds: 1000 - since));
        }
        if (_cancelled) return RecognitionOutcome.error('Cancelled.');

        onPhase?.call(RecognitionPhase.querying);
        lastQueryMs = DateTime.now().millisecondsSinceEpoch;
        final outcome = await _queryFingerprintService(signature, sampleDurationMs);
        // RE-CHECK AFTER the await, not just before it.
        //
        // `cancel()` flips `_cancelled` and stops the recorder, but it cannot
        // abort an HTTP request that is already in flight. Every other cancel
        // check in this method sits BEFORE a long operation, so a tap on Cancel
        // during the network round-trip was ignored: the query finished, this
        // returned success, and the sheet presented a match for a recognition
        // the user had already dismissed — seconds after the UI said it stopped.
        if (_cancelled) return RecognitionOutcome.error('Cancelled.');
        if (outcome.isSuccess) return outcome;
        lastOutcome = outcome;

        // No more audio will arrive — no point escalating further.
        if (streamDone) break;
        onPhase?.call(RecognitionPhase.listening); // keep the animation alive
      }
      return lastOutcome;
    } catch (e) {
      debugPrint('[$_tag] recognize failed: $e');
      return RecognitionOutcome.error('Recognition failed. Please try again.');
    } finally {
      await sub?.cancel();
      try {
        if (await _recorder.isRecording()) await _recorder.stop();
      } catch (_) {}
    }
  }
  Future<RecognitionOutcome> _queryFingerprintService(
      String signature, int sampleDurationMs) async {
    final uuid1 = _uuidV4().toUpperCase();
    final uuid2 = _uuidV4();
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // NO FAKE GEOLOCATION. This used to send a randomised altitude, latitude
    // and longitude on every query — coordinates that were not the user's and not
    // anyone's, generated purely so consecutive requests looked like they came
    // from different people in different places.
    //
    // The field is omitted rather than filled with a real position: Auvy does not
    // hold location permission and has no reason to start, and the endpoint does
    // not require it. Sending nothing is both honest and the more private option —
    // the previous code leaked no real location either, but it did make the app
    // lie about where it was.
    //
    // The timezone is the DEVICE'S actual one. It is a coarse, non-identifying
    // value the request shape expects, and reporting it truthfully costs nothing.
    final body = jsonEncode({
      'signature': {
        'samplems': sampleDurationMs,
        'timestamp': timestamp,
        'uri': signature,
      },
      'timestamp': timestamp,
      'timezone': DateTime.now().timeZoneName,
    });

    final uri = Uri.parse(
      'https://amp.shazam.com/discovery/v5/en/US/android/-/tag/$uuid1/$uuid2',
    ).replace(queryParameters: {
      'sync': 'true',
      'webv3': 'true',
      'sampling': 'true',
      'connected': '',
      'shazamapiversion': 'v3',
      'sharehub': 'true',
      'video': 'v3',
    });

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'User-Agent': _userAgent,
              'Content-Language': 'en_US',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[$_tag] Shazam HTTP ${response.statusCode}');
        switch (response.statusCode) {
          case 429:
            return RecognitionOutcome.error(
                'Too many requests — wait a moment and try again.');
          case 404:
            return RecognitionOutcome.noMatch();
          default:
            if (response.statusCode >= 500) {
              return RecognitionOutcome.error(
                  'Shazam service temporarily unavailable.');
            }
            return RecognitionOutcome.error(
                'Recognition failed (error ${response.statusCode}).');
        }
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final result = _parseResult(json);
      return result == null
          ? RecognitionOutcome.noMatch()
          : RecognitionOutcome.success(result);
    } on TimeoutException {
      return RecognitionOutcome.error('Recognition timed out.');
    } catch (e) {
      debugPrint('[$_tag] Shazam query failed: $e');
      return RecognitionOutcome.error('Recognition failed. Please try again.');
    }
  }

  SongRecognitionResult? _parseResult(Map<String, dynamic> json) {
    final track = json['track'] as Map<String, dynamic>?;
    if (track == null) return null;

    final sections = (track['sections'] as List?) ?? const [];
    Map<String, dynamic>? sectionByType(String type) {
      for (final s in sections) {
        if (s is Map && s['type'] == type) return Map<String, dynamic>.from(s);
      }
      return null;
    }

    String? metaText(Map<String, dynamic>? section, String title) {
      final meta = (section?['metadata'] as List?) ?? const [];
      for (final m in meta) {
        if (m is Map && m['title'] == title) return m['text'] as String?;
      }
      return null;
    }

    final songSection = sectionByType('SONG');
    final album = metaText(songSection, 'Album');
    final label = metaText(songSection, 'Label');
    final releaseDate = metaText(songSection, 'Released');

    final hub = track['hub'] as Map<String, dynamic>?;
    final options = (hub?['options'] as List?) ?? const [];
    final providers = (hub?['providers'] as List?) ?? const [];

    String? firstActionUri(Map source) {
      final actions = (source['actions'] as List?) ?? const [];
      for (final a in actions) {
        if (a is Map && a['uri'] is String) return a['uri'] as String;
      }
      return null;
    }

    String? appleMusicUrl;
    String? youtubeUri;
    for (final o in options) {
      if (o is! Map) continue;
      final provider = (o['providername'] as String?)?.toLowerCase() ?? '';
      final type = (o['type'] as String?)?.toLowerCase() ?? '';
      if (appleMusicUrl == null && provider.contains('apple')) {
        appleMusicUrl = firstActionUri(o);
      }
      if (youtubeUri == null && type.contains('video')) {
        youtubeUri = firstActionUri(o);
      }
    }

    String? spotifyUrl;
    for (final p in providers) {
      if (p is! Map) continue;
      final caption = (p['caption'] as String?)?.toLowerCase() ?? '';
      if (caption.contains('spotify')) {
        spotifyUrl = firstActionUri(p);
        break;
      }
    }

    final images = track['images'] as Map<String, dynamic>?;
    final genres = track['genres'] as Map<String, dynamic>?;

    return SongRecognitionResult(
      trackId: (track['key'] as String?) ?? (json['tagid'] as String?) ?? '',
      title: (track['title'] as String?) ?? '',
      artist: (track['subtitle'] as String?) ?? '',
      album: album,
      coverArtUrl: images?['coverart'] as String?,
      coverArtHqUrl: images?['coverarthq'] as String?,
      genre: genres?['primary'] as String?,
      releaseDate: releaseDate,
      label: label,
      shazamUrl: track['url'] as String?,
      appleMusicUrl: appleMusicUrl,
      spotifyUrl: spotifyUrl,
      isrc: track['isrc'] as String?,
      youtubeVideoId: _extractVideoId(youtubeUri),
    );
  }

  String? _extractVideoId(String? uri) {
    if (uri == null || uri.isEmpty) return null;
    final afterV = uri.split('v=');
    if (afterV.length > 1 && afterV.last.isNotEmpty) {
      // Trim any trailing params.
      return afterV.last.split('&').first;
    }
    final lastSeg = uri.split('/').last;
    return lastSeg.length == 11 ? lastSeg : null;
  }

  String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
