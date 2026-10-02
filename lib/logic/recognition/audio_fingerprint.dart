// lib/logic/recognition/audio_fingerprint.dart
//
// ┌─ DERIVED WORK — GPL-3.0 ──────────────────────────────────────────────────┐
// │ Derived from SongRec (© marin-m, GPL-3.0) by way of Metrolist's           │
// │ ShazamSignatureGenerator.kt (© Metrolist Group, GPL-3.0).                 │
// │                                                                          │
// │ MODIFIED by Akram Ahmed: translated to Dart, restructured for Flutter,   │
// │ and reworked to run without native code. Modified through 2026.          │
// │                                                                          │
// │ This file is why Auvy as a whole is GPL-3.0. See LICENSE for the full     │
// │ terms and NOTICE.md for what came from where.                            │
// │                                                                          │
// │ This program is free software: you can redistribute it and/or modify it   │
// │ under the terms of the GNU General Public License as published by the     │
// │ Free Software Foundation, either version 3 of the License, or (at your    │
// │ option) any later version. It is distributed WITHOUT ANY WARRANTY;        │
// │ without even the implied warranty of MERCHANTABILITY or FITNESS FOR A     │
// │ PARTICULAR PURPOSE. See the GNU General Public License for more details.  │
// └──────────────────────────────────────────────────────────────────────────┘
//
// KEEP THIS HEADER. GPL-3.0 §5(a) requires a modified work to carry prominent
// notices saying it was changed and when, and §4 requires the licence notices to
// be preserved on every copy. NOTICE.md records the attribution at project level,
// but a file that travels on its own — copied into a gist, a Stack Overflow
// answer, another project — must carry its own provenance or the next person
// cannot know what licence binds it.
//
// Pure-Dart implementation of the Shazam audio fingerprinting algorithm.
//
// Ported line-for-line from Metrolist's `ShazamSignatureGenerator.kt`, which in
// turn ports the vibra / SongRec C++ implementation
// (https://github.com/marin-m/SongRec). No native code, no FFTW3 — an iterative
// radix-2 FFT + peak spreading/recognition + the Shazam binary signature
// container, all in Dart so it runs on any platform Auvy targets.
//
// Input:  mono 16-bit signed little-endian PCM at 16 kHz.
// Output: `data:audio/vnd.shazam.sig;base64,...` signature URI accepted by the
//         amp.shazam.com discovery endpoint.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

const int _sampleRate = 16000;
const int _fftSize = 2048;
const int _fftOutputSize = _fftSize ~/ 2 + 1; // 1025
const int _maxPeaks = 255;
const double _maxTimeSeconds = 12.0;
const int _ringBufSize = 256;

// Frequency band ids (match the FrequencyBand enum in the C++ original).
const int _band250520 = 0;
const int _band5201450 = 1;
const int _band14503500 = 2;
const int _band35005500 = 3;

/// Hanning window: w[i] = 0.5 * (1 - cos(2π*(i+1)/2049)) for i=0..2047 — matches
/// the precomputed HANNIG_MATRIX in the C++ hanning.h header.
final Float64List _hanning = Float64List(_fftSize)
  ..setRange(
    0,
    _fftSize,
    List<double>.generate(
      _fftSize,
      (i) => 0.5 * (1.0 - math.cos(2.0 * math.pi * (i + 1) / 2049.0)),
    ),
  );

/// Standard zlib/IEEE CRC32 (reflected, poly 0xEDB88320) — the same algorithm as
/// java.util.zip.CRC32 used by the Kotlin original.
final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c & 0xFFFFFFFF;
  }
  return table;
}

int _crc32(Uint8List data, int start, int length) {
  int crc = 0xFFFFFFFF;
  final end = start + length;
  for (int i = start; i < end; i++) {
    crc = _crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

class _FrequencyPeak {
  final int fftPassNumber;
  final int peakMagnitude;
  final int correctedPeakFrequencyBin;
  _FrequencyPeak(
      this.fftPassNumber, this.peakMagnitude, this.correctedPeakFrequencyBin);
}

/// Generates a Shazam-compatible audio fingerprint from raw 16-bit PCM samples.
///
/// [samples] must be mono, 16-bit signed little-endian PCM at 16 kHz with an
/// even length. Returns the signature URI string.
String generateAudioFingerprint(Uint8List samples) {
  if (samples.length < 2 || samples.length.isOdd) {
    throw ArgumentError(
        'samples must be a non-empty byte array with even length (16-bit PCM)');
  }
  final pcm = samples.buffer.asInt16List(samples.offsetInBytes, samples.length ~/ 2);
  return _SignatureGeneratorState().process(pcm);
}

class _SignatureGeneratorState {
  // Circular buffer for 2048 raw samples.
  final Int32List _samplesRing = Int32List(_fftSize);
  int _samplesPos = 0;

  // Circular buffer of FFT magnitude outputs.
  final List<Float64List> _fftOutputs =
      List.generate(_ringBufSize, (_) => Float64List(_fftOutputSize));
  int _fftPos = 0;

  // Circular buffer of time-spread FFT outputs.
  final List<Float64List> _spreadFfts =
      List.generate(_ringBufSize, (_) => Float64List(_fftOutputSize));
  int _spreadPos = 0;
  int _spreadNumWritten = 0;

  int _numSamples = 0;

  // Band -> peaks (bands 0..3).
  final List<List<_FrequencyPeak>> _bandPeaks =
      List.generate(4, (_) => <_FrequencyPeak>[]);
  int _totalPeaks = 0;

  // Reusable scratch buffers for the FFT (allocated once).
  final Float64List _re = Float64List(_fftSize);
  final Float64List _im = Float64List(_fftSize);

  String process(Int16List pcm) {
    int offset = 0;
    while (offset + 128 <= pcm.length) {
      // Match the C++ stopping condition: stop when BOTH time>=max AND peaks>=max.
      final elapsedSec = _numSamples / _sampleRate;
      if (elapsedSec >= _maxTimeSeconds && _totalPeaks >= _maxPeaks) break;

      _numSamples += 128;
      _feedSamples(pcm, offset, 128);
      _doFft();
      _doPeakSpreading();
      if (_spreadNumWritten >= 47) _doPeakRecognition();
      offset += 128;
    }
    return _encodeSignature();
  }

  void _feedSamples(Int16List pcm, int start, int count) {
    for (int k = start; k < start + count; k++) {
      _samplesRing[_samplesPos] = pcm[k];
      _samplesPos = (_samplesPos + 1) % _fftSize;
    }
  }

  void _doFft() {
    for (int i = 0; i < _fftSize; i++) {
      _re[i] = _samplesRing[(_samplesPos + i) % _fftSize] * _hanning[i];
    }
    _computeRfft(_fftOutputs[_fftPos]);
    _fftPos = (_fftPos + 1) % _ringBufSize;
  }

  /// Iterative Cooley-Tukey radix-2 DIT real FFT of the windowed samples held in
  /// [_re] (length 2048), writing FFT_OUTPUT_SIZE (1025) magnitudes into [out]:
  ///   magnitude[k] = max((re[k]² + im[k]²) / 2^17, 1e-10)
  /// matching the FFTW3 r2c output format used by the C++ vibra library.
  void _computeRfft(Float64List out) {
    const n = _fftSize; // 2048
    final re = _re; // holds the windowed input; transformed in place
    final im = _im;
    for (int i = 0; i < n; i++) {
      im[i] = 0.0;
    }

    // Bit-reversal permutation.
    int j = 0;
    for (int i = 1; i < n; i++) {
      int bit = n >> 1;
      while ((j & bit) != 0) {
        j ^= bit;
        bit >>= 1;
      }
      j ^= bit;
      if (i < j) {
        double tmp = re[i];
        re[i] = re[j];
        re[j] = tmp;
        tmp = im[i];
        im[i] = im[j];
        im[j] = tmp;
      }
    }

    // Cooley-Tukey butterfly stages (11 stages for n=2048).
    int len = 2;
    while (len <= n) {
      final halfLen = len >> 1;
      final ang = -math.pi / halfLen; // = -2π / len
      final wBaseRe = math.cos(ang);
      final wBaseIm = math.sin(ang);
      int i = 0;
      while (i < n) {
        double wRe = 1.0;
        double wIm = 0.0;
        for (int k = 0; k < halfLen; k++) {
          final u = i + k;
          final v = u + halfLen;
          final evenRe = re[u];
          final evenIm = im[u];
          final oddRe = re[v] * wRe - im[v] * wIm;
          final oddIm = re[v] * wIm + im[v] * wRe;
          re[u] = evenRe + oddRe;
          im[u] = evenIm + oddIm;
          re[v] = evenRe - oddRe;
          im[v] = evenIm - oddIm;
          final newWRe = wRe * wBaseRe - wIm * wBaseIm;
          wIm = wRe * wBaseIm + wIm * wBaseRe;
          wRe = newWRe;
        }
        i += len;
      }
      len <<= 1;
    }

    // Extract magnitudes for bins 0..n/2.
    const scaleFactor = 1.0 / (1 << 17);
    const minVal = 1e-10;
    for (int idx = 0; idx < _fftOutputSize; idx++) {
      final r = re[idx];
      final img = im[idx];
      final mag = (r * r + img * img) * scaleFactor;
      out[idx] = mag < minVal ? minVal : mag;
    }
  }

  void _doPeakSpreading() {
    // Start with a copy of the last FFT output.
    final lastFftIdx = (_fftPos - 1 + _ringBufSize) % _ringBufSize;
    final spread = Float64List.fromList(_fftOutputs[lastFftIdx]);

    // Frequency spreading: 3-point running max (forward pass).
    for (int pos = 0; pos < _fftOutputSize - 2; pos++) {
      final a = spread[pos];
      final b = spread[pos + 1];
      final c = spread[pos + 2];
      spread[pos] = a > b ? (a > c ? a : c) : (b > c ? b : c);
    }

    // Time spreading: propagate max into older spread entries at offsets -1,-3,-6.
    // The new entry keeps only frequency spreading (matches the C++ original).
    const offsets = [-1, -3, -6];
    for (int pos = 0; pos < _fftOutputSize; pos++) {
      double maxVal = spread[pos];
      for (final offset in offsets) {
        final idx = ((_spreadPos + offset) % _ringBufSize + _ringBufSize) % _ringBufSize;
        final oldVal = _spreadFfts[idx][pos];
        if (oldVal > maxVal) maxVal = oldVal;
        _spreadFfts[idx][pos] = maxVal;
      }
    }

    _spreadFfts[_spreadPos].setRange(0, _fftOutputSize, spread);
    _spreadPos = (_spreadPos + 1) % _ringBufSize;
    _spreadNumWritten++;
  }

  static const List<int> _otherOffsets = [
    -53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249
  ];
  static const List<int> _neighborOffsets = [-10, -7, -4, -3, 1, 2, 5, 8];

  void _doPeakRecognition() {
    final fftMinus46 = _fftOutputs[(_fftPos - 46 + _ringBufSize * 2) % _ringBufSize];
    final spreadMinus49 = _spreadFfts[(_spreadPos - 49 + _ringBufSize * 2) % _ringBufSize];

    for (int binPos = 10; binPos < _fftOutputSize - 8; binPos++) {
      final fftVal = fftMinus46[binPos];
      if (fftVal < 1.0 / 64.0 || fftVal < spreadMinus49[binPos]) continue;

      // Check 8 neighbours in spreadMinus49.
      double maxNeighborSpread49 = 0.0;
      for (final n in _neighborOffsets) {
        final v = spreadMinus49[binPos + n];
        if (v > maxNeighborSpread49) maxNeighborSpread49 = v;
      }
      if (fftVal <= maxNeighborSpread49) continue;

      // Check 14 other spread FFT offsets.
      double maxNeighborOther = maxNeighborSpread49;
      for (final otherOffset in _otherOffsets) {
        final spreadIdx =
            ((_spreadPos + otherOffset) % _ringBufSize + _ringBufSize) % _ringBufSize;
        final v = _spreadFfts[spreadIdx][binPos - 1];
        if (v > maxNeighborOther) maxNeighborOther = v;
      }
      if (fftVal <= maxNeighborOther) continue;

      // Valid peak — compute corrected bin and frequency.
      final fftNumber = _spreadNumWritten - 46;

      final peakMag = math.log(math.max(1.0 / 64.0, fftVal)) * 1477.3 + 6144;
      final peakMagBefore =
          math.log(math.max(1.0 / 64.0, fftMinus46[binPos - 1])) * 1477.3 + 6144;
      final peakMagAfter =
          math.log(math.max(1.0 / 64.0, fftMinus46[binPos + 1])) * 1477.3 + 6144;

      final peakVariation1 = peakMag * 2 - peakMagBefore - peakMagAfter;
      final peakVariation2 = (peakMagAfter - peakMagBefore) * 32 / peakVariation1;

      final correctedBin = binPos * 64.0 + peakVariation2;
      final frequencyHz = correctedBin * (16000.0 / 2.0 / 1024.0 / 64.0);

      // NaN/Infinity frequencies fall through every comparison to `continue`,
      // so correctedBin is always finite before toInt() below (avoids the Dart
      // "Infinity/NaN toInt" exception the JVM's silent truncation hides).
      int band;
      if (frequencyHz < 250.0) {
        continue;
      } else if (frequencyHz < 520.0) {
        band = _band250520;
      } else if (frequencyHz < 1450.0) {
        band = _band5201450;
      } else if (frequencyHz < 3500.0) {
        band = _band14503500;
      } else if (frequencyHz <= 5500.0) {
        band = _band35005500;
      } else {
        continue;
      }

      _bandPeaks[band].add(_FrequencyPeak(
        fftNumber,
        peakMag.toInt(),
        correctedBin.toInt(),
      ));
      _totalPeaks++;
    }
  }

  String _encodeSignature() {
    final contentsStream = BytesBuilder();

    // Write each band's peaks in ascending band order (matches C++ std::map).
    for (int bandId = 0; bandId <= 3; bandId++) {
      final peaks = _bandPeaks[bandId];
      if (peaks.isEmpty) continue;

      final peakBuf = BytesBuilder();
      int prevFftPassNumber = 0;

      for (final peak in peaks) {
        final diff = peak.fftPassNumber - prevFftPassNumber;
        if (diff >= 255) {
          // Absolute position with 0xFF marker.
          peakBuf.addByte(0xFF);
          _writeLe32(peakBuf, peak.fftPassNumber);
          prevFftPassNumber = peak.fftPassNumber;
        }
        peakBuf.addByte((peak.fftPassNumber - prevFftPassNumber) & 0xFF);
        _writeLe16(peakBuf, peak.peakMagnitude);
        _writeLe16(peakBuf, peak.correctedPeakFrequencyBin);
        prevFftPassNumber = peak.fftPassNumber;
      }

      final peakBytes = peakBuf.toBytes();

      // Band tag: 0x60030040 + bandId.
      _writeLe32(contentsStream, 0x60030040 + bandId);
      _writeLe32(contentsStream, peakBytes.length);
      contentsStream.add(peakBytes);

      // Pad to 4-byte alignment.
      final padBytes = (4 - peakBytes.length % 4) % 4;
      for (int i = 0; i < padBytes; i++) {
        contentsStream.addByte(0);
      }
    }

    final contents = contentsStream.toBytes();
    final sizeMinusHeader = contents.length + 8;
    final samplesAndOffset = (_numSamples + _sampleRate * 0.24).toInt();

    // 48-byte header (all fields little-endian).
    final header = ByteData(48);
    header.setUint32(0, 0xcafe2580, Endian.little); // magic1
    header.setUint32(4, 0, Endian.little); // crc32 placeholder
    header.setUint32(8, sizeMinusHeader & 0xFFFFFFFF, Endian.little);
    header.setUint32(12, 0x94119c00, Endian.little); // magic2
    header.setUint32(16, 0, Endian.little); // void1[0]
    header.setUint32(20, 0, Endian.little); // void1[1]
    header.setUint32(24, 0, Endian.little); // void1[2]
    header.setUint32(28, 3 << 27, Endian.little); // shifted_sample_rate_id
    header.setUint32(32, 0, Endian.little); // void2[0]
    header.setUint32(36, 0, Endian.little); // void2[1]
    header.setUint32(40, samplesAndOffset & 0xFFFFFFFF, Endian.little);
    header.setUint32(44, (15 << 19) + 0x40000, Endian.little); // fixed_value

    // Assemble: header(48) + 0x40000000(4) + sizeMinusHeader(4) + contents.
    final fullBuf = BytesBuilder();
    fullBuf.add(header.buffer.asUint8List());
    _writeLe32(fullBuf, 0x40000000);
    _writeLe32(fullBuf, contents.length + 8);
    fullBuf.add(contents);

    final fullBytes = fullBuf.toBytes();

    // CRC32 over bytes 8..end (skips magic1 and the crc32 field itself).
    final crc = _crc32(fullBytes, 8, fullBytes.length - 8);
    fullBytes[4] = crc & 0xFF;
    fullBytes[5] = (crc >>> 8) & 0xFF;
    fullBytes[6] = (crc >>> 16) & 0xFF;
    fullBytes[7] = (crc >>> 24) & 0xFF;

    return 'data:audio/vnd.shazam.sig;base64,${base64.encode(fullBytes)}';
  }
}

void _writeLe32(BytesBuilder out, int value) {
  out.addByte(value & 0xFF);
  out.addByte((value >>> 8) & 0xFF);
  out.addByte((value >>> 16) & 0xFF);
  out.addByte((value >>> 24) & 0xFF);
}

void _writeLe16(BytesBuilder out, int value) {
  out.addByte(value & 0xFF);
  out.addByte((value >>> 8) & 0xFF);
}

/// Resamples mono 16-bit PCM using linear interpolation — the textbook approach:
/// ratio, allocate, interpolate between neighbouring samples. Returns bytes at
/// [outRate]; a no-op copy when the rates already match.
Uint8List resamplePcm16(Uint8List data, int inRate, int outRate) {
  if (inRate == outRate) return data;
  final input = data.buffer.asInt16List(data.offsetInBytes, data.length ~/ 2);
  final ratio = outRate / inRate;
  final outputLength = (input.length * ratio).toInt();
  final output = Int16List(outputLength);
  for (int i = 0; i < outputLength; i++) {
    final srcPos = i / ratio;
    final srcIndex = srcPos.toInt();
    final fraction = srcPos - srcIndex;
    if (srcIndex + 1 < input.length) {
      output[i] =
          (input[srcIndex] * (1.0 - fraction) + input[srcIndex + 1] * fraction)
              .toInt();
    } else {
      output[i] = input[srcIndex];
    }
  }
  return output.buffer.asUint8List(output.offsetInBytes, output.lengthInBytes);
}
