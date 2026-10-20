import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:auvy/core/native_audio_engine.dart';
import 'package:auvy/providers/slider_provider.dart';

/// One song's waveform for the player's slider: [levels] holds one loudness per
/// slice of the song, 0..1, or null where that part isn't known yet.
@immutable
class WaveformData {
  final String songId;
  final List<double?> levels;

  /// Every slice is known (decoded from the file), not being filled in.
  final bool complete;

  const WaveformData(this.songId, this.levels, {required this.complete});
}

/// The real waveform of the song playing, for the waveform slider.
///
/// The native player decodes it from the song's file: both players fetch every
/// song whole to a file before it plays (a cached, downloaded or on-device song
/// already is one), and the next song in the current one's last seconds. It is
/// kept per song on this device, so a song seen once draws at once. Whenever the
/// waveform style is chosen (or a waveform slider is on screen), each song is
/// decoded as soon as its file is in (onFetched): the one about to play, and the
/// next, fetched ahead. So its waveform is there when the song starts or the
/// player is opened, even after a while with the screen off. Until a file is in,
/// and for a stream that is never a file (radio, or a song that could not be
/// fetched), the shape fills in from the level meter's readings as it plays
/// (the same measure, RMS, that the decode uses).
class TrackWaveform {
  TrackWaveform._();
  static final TrackWaveform instance = TrackWaveform._();

  /// Slices per song: about one per line of the slider, so each line is its own
  /// moment (under half a second of a three-minute song).
  static const int slices = 400;

  /// Songs kept on disk; the oldest go first. 400 bytes each.
  static const int _maxStored = 1000;

  final ValueNotifier<WaveformData?> current = ValueNotifier(null);

  /// Song id → levels quantised to 0..255, oldest first.
  final Map<String, Uint8List> _stored = {};
  Future<void>? _loading;
  Timer? _saveTimer;

  /// Waveform sliders on screen. Songs are decoded as their files land while one
  /// is, or while the waveform style is the saved choice.
  int _watchers = 0;

  /// Decodes under way, by song, so two asks for one song share one decode.
  final Map<String, Future<List<double>?>> _decoding = {};

  /// The song being filled in from the meter.
  String? _recordingFor;
  final List<double> _sums = List.filled(slices, 0);
  final List<int> _counts = List.filled(slices, 0);
  Timer? _publishTimer;

  /// Hears about each song's file as it lands. Called once the player is set up.
  void listen() => NativeAudioEngine.onFetched ??= _fetched;

  /// A waveform slider came on screen.
  void watch() {
    _watchers++;
    listen();
  }

  /// A waveform slider left the screen.
  void unwatch() {
    if (_watchers > 0) _watchers--;
  }

  /// Shows [songId]'s waveform: the stored one, else a decode of the song's
  /// file, else an empty one the meter fills in.
  Future<void> show(String songId) async {
    if (current.value?.songId == songId) return;
    _recordingFor = null;
    await (_loading ??= _load());
    final stored = _stored[songId];
    if (stored != null) {
      // Touch it, so the songs played most stay longest.
      _stored.remove(songId);
      _stored[songId] = stored;
      current.value = WaveformData(songId, [for (final b in stored) b / 255], complete: true);
      return;
    }
    // Recording starts BEFORE the empty waveform is published: the slider decides
    // on that notification whether to switch the meter on, and asks only then.
    _startRecording(songId);
    current.value = WaveformData(songId, List<double?>.filled(slices, null), complete: false);
    // The song's file may still be on its way (the previous song stays in the
    // player until it is): onFetched asks again the moment it is in, and these
    // asks cover a file that was in before this slider was. Each ask that finds
    // nothing costs a file check, not a decode.
    for (final wait in const [0, 2, 5, 10, 20]) {
      if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
      // Done when the song changed, or onFetched already filled it in.
      if (current.value?.songId != songId || current.value!.complete) return;
      final peaks = await _decode(songId);
      if (peaks == null) continue;
      _show(songId, peaks, 'decoded');
      return;
    }
  }

  /// A song's whole file is in: the one playing, or the next, fetched ahead.
  /// Decoded only for someone who uses the waveform style, and only once.
  Future<void> _fetched(String songId) async {
    if (_watchers == 0 && !await SliderStyleNotifier.waveformChosen()) return;
    await (_loading ??= _load());
    final now = current.value;
    final playing = now?.songId == songId;
    if (playing ? now!.complete : _stored.containsKey(songId)) return;
    final peaks = await _decode(songId);
    if (peaks == null) return;
    if (current.value?.songId == songId) {
      _show(songId, peaks, 'decoded once fetched');
    } else {
      _store(songId, peaks);
      print('waveform: $songId decoded ahead');
    }
  }

  /// Stores [songId]'s decoded waveform and shows it, unless the song changed or
  /// its waveform is already whole.
  void _show(String songId, List<double> peaks, String how) {
    final now = current.value;
    if (now?.songId != songId || now!.complete) return;
    _recordingFor = null;
    _store(songId, peaks);
    current.value = WaveformData(songId, peaks, complete: true);
    print('waveform: $songId $how');
  }

  /// The native decode of [songId]'s file, or null when there is no whole file
  /// to read yet. Two asks for one song share one decode.
  Future<List<double>?> _decode(String songId) => _decoding[songId] ??= () async {
        try {
          final decoded = await NativeAudioEngine.waveform(buckets: slices, videoId: songId);
          if (decoded == null || decoded.peaks.length != slices || decoded.videoId != songId) return null;
          return decoded.peaks;
        } finally {
          _decoding.remove(songId);
        }
      }();

  /// Whether the meter's readings are wanted: a song is being filled in.
  bool get wantsReadings => _recordingFor != null;

  /// One meter reading for [songId], taken at [progress] (0..1) of the song.
  void record(String songId, double progress, double rms) {
    if (_recordingFor != songId || rms <= 0) return;
    final i = (progress * slices).floor().clamp(0, slices - 1);
    _sums[i] += rms;
    _counts[i]++;
    _publishTimer ??= Timer(const Duration(milliseconds: 400), _publishRecording);
  }

  void _startRecording(String songId) {
    _recordingFor = songId;
    _sums.fillRange(0, slices, 0);
    _counts.fillRange(0, slices, 0);
  }

  /// The filled-in slices so far, each relative to the loudest heard yet.
  void _publishRecording() {
    _publishTimer = null;
    final songId = _recordingFor;
    if (songId == null || current.value?.songId != songId) return;
    final means = [for (var i = 0; i < slices; i++) _counts[i] > 0 ? _sums[i] / _counts[i] : null];
    var loudest = 0.0;
    for (final m in means) {
      if (m != null && m > loudest) loudest = m;
    }
    if (loudest <= 0) return;
    current.value = WaveformData(
        songId, [for (final m in means) m == null ? null : m / loudest],
        complete: false);
  }

  void _store(String songId, List<double> levels) {
    _stored.remove(songId);
    _stored[songId] = Uint8List.fromList([for (final v in levels) (v * 255).round().clamp(0, 255)]);
    while (_stored.length > _maxStored) {
      _stored.remove(_stored.keys.first);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () => unawaited(_save()));
  }

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}/waveforms.json');

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final e in map.entries) {
        final bytes = base64Decode(e.value as String);
        if (bytes.length == slices) _stored[e.key] = bytes;
      }
    } catch (e) {
      // A damaged file costs only re-decoding; start empty.
      print('waveform: stored waveforms unreadable ($e), starting empty');
    }
  }

  Future<void> _save() async {
    try {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({for (final e in _stored.entries) e.key: base64Encode(e.value)}));
      await tmp.rename(file.path);
    } catch (e) {
      print('waveform: could not save waveforms ($e)');
    }
  }
}
