package com.auvy.app

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.util.Log
import java.nio.ByteOrder
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/**
 * The real waveform of a track for the player's waveform slider: its loudness
 * (RMS) in `buckets` equal slices, each 0..1 relative to the loudest slice. The
 * same measure as iOS's AuvyWaveform, so the two draw alike.
 *
 * Decodes a local file (a fetched, cached, downloaded or on-device song) with
 * the platform's own decoder. Null for anything longer than 20 minutes (a
 * podcast or audiobook takes long to decode, and a waveform says little there).
 * Runs on the caller's thread and a few of its own: call it off the main
 * thread. [superseded] is checked as it goes: once a newer request has replaced
 * this one, it stops and answers null rather than finish for nothing.
 *
 * The song is decoded in [PARTS] stretches at once, each by its own decoder.
 * Android's software audio decoders run in a separate system process, and every
 * 20 ms frame makes a trip there and back; one decoder took about 7 s for a
 * 3-minute song waiting on those trips, not decoding. Several
 * decoders wait side by side, so the same work finishes in a fraction of the
 * time. (iOS decodes in the app's own process and needs none of this.)
 */
object WaveformDecoder {
    private const val TAG = "WaveformDecoder"
    private const val MAX_DURATION_US = 20L * 60 * 1_000_000
    private const val TIMEOUT_US = 10_000L

    /** Stretches decoded at once. */
    private const val PARTS = 4

    /** A song shorter than this per stretch is decoded in fewer of them. */
    private const val MIN_PART_US = 20L * 1_000_000

    /**
     * Threads for the stretches after the first (which runs on the caller's),
     * below playback and the UI. Created on demand and ended after a minute
     * unused, so nothing lingers.
     */
    private val pool = Executors.newCachedThreadPool { r ->
        Thread({
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            r.run()
        }, "waveform-part")
    }

    private class Totals(buckets: Int) {
        val sums = DoubleArray(buckets)
        val counts = LongArray(buckets)
    }

    fun decode(context: Context, uri: Uri, buckets: Int, superseded: () -> Boolean = { false }): DoubleArray? {
        if (buckets <= 0 || superseded()) return null
        val durationUs = try {
            durationOf(context, uri)
        } catch (e: Exception) {
            Log.w(TAG, "no waveform for $uri: $e")
            return null
        }
        if (durationUs <= 0 || durationUs > MAX_DURATION_US) return null

        val parts = (durationUs / MIN_PART_US).toInt().coerceIn(1, PARTS)
        val bounds = LongArray(parts + 1) { durationUs * it / parts }
        // The last stretch runs to the end of the file, whatever the header says.
        bounds[parts] = Long.MAX_VALUE
        val others = (1 until parts).map { i ->
            pool.submit(Callable { decodePart(context, uri, buckets, durationUs, bounds[i], bounds[i + 1], superseded) })
        }
        val first = decodePart(context, uri, buckets, durationUs, bounds[0], bounds[1], superseded)
        val rest = others.map { f -> try { f.get() } catch (_: Exception) { null } }
        if (first == null || rest.any { it == null }) return null

        val totals = Totals(buckets)
        for (part in listOf(first) + rest.filterNotNull()) {
            for (b in 0 until buckets) {
                totals.sums[b] += part.sums[b]
                totals.counts[b] += part.counts[b]
            }
        }
        val rms = DoubleArray(buckets) { if (totals.counts[it] > 0) Math.sqrt(totals.sums[it] / totals.counts[it]) else 0.0 }
        val loudest = rms.maxOrNull() ?: 0.0
        if (loudest <= 0.0) return null
        return DoubleArray(buckets) { rms[it] / loudest }
    }

    /** The audio track's duration from the file's header, or 0. */
    private fun durationOf(context: Context, uri: Uri): Long {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(context, uri, null)
            val track = audioTrack(extractor) ?: return 0L
            val format = extractor.getTrackFormat(track)
            return if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else 0L
        } finally {
            extractor.release()
        }
    }

    private fun audioTrack(extractor: MediaExtractor): Int? = (0 until extractor.trackCount).firstOrNull {
        extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
    }

    /**
     * The loudness totals of the frames that start in [startUs, endUs). The
     * extractor seeks to the sync point at or before [startUs]; frames decoded
     * before it only prime the decoder and are not counted, so no frame is
     * counted by two stretches.
     */
    private fun decodePart(
        context: Context, uri: Uri, buckets: Int, durationUs: Long,
        startUs: Long, endUs: Long, superseded: () -> Boolean,
    ): Totals? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = audioTrack(extractor) ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            if (startUs > 0) extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()

            val totals = Totals(buckets)
            val info = MediaCodec.BufferInfo()
            var floatPcm = false
            var inputDone = false
            var outputDone = false
            // Every free input buffer is filled and every ready output taken each
            // round, waiting only when nothing came out. One buffer in and one out
            // per round, each with its own wait, left the decoder idle between
            // frames (about 13 s for a 3.5-minute song).
            while (!outputDone) {
                if (superseded()) return null
                while (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(0)
                    if (inIndex < 0) break
                    val buffer = decoder.getInputBuffer(inIndex)!!
                    val size = extractor.readSampleData(buffer, 0)
                    // The stretch ends at the first frame past it (or the file's end).
                    if (size < 0 || extractor.sampleTime >= endUs) {
                        decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
                var outIndex = decoder.dequeueOutputBuffer(info, TIMEOUT_US)
                while (outIndex != MediaCodec.INFO_TRY_AGAIN_LATER && !outputDone) {
                    if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val out = decoder.outputFormat
                        floatPcm = out.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            out.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                    } else if (outIndex >= 0) {
                        val out = decoder.getOutputBuffer(outIndex)
                        val pts = info.presentationTimeUs
                        if (out != null && info.size > 0 && pts >= startUs && pts < endUs) {
                            out.position(info.offset)
                            out.limit(info.offset + info.size)
                            // One output buffer is tens of milliseconds, a slice a couple of
                            // seconds, so the whole buffer goes to the slice it starts in.
                            val b = ((pts.coerceAtLeast(0) * buckets) / durationUs)
                                .toInt().coerceIn(0, buckets - 1)
                            var sum = 0.0
                            var n = 0L
                            // Every fourth sample: plenty for a slice's loudness, a quarter the work.
                            if (floatPcm) {
                                val samples = out.order(ByteOrder.nativeOrder()).asFloatBuffer()
                                var i = 0
                                while (i < samples.remaining()) { val v = samples.get(i).toDouble(); sum += v * v; n++; i += 4 }
                            } else {
                                val samples = out.order(ByteOrder.nativeOrder()).asShortBuffer()
                                var i = 0
                                while (i < samples.remaining()) { val v = samples.get(i) / 32768.0; sum += v * v; n++; i += 4 }
                            }
                            totals.sums[b] += sum
                            totals.counts[b] += n
                        }
                        decoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                    if (!outputDone) outIndex = decoder.dequeueOutputBuffer(info, 0)
                }
            }
            return totals
        } catch (e: Exception) {
            Log.w(TAG, "no waveform for $uri ($startUs–$endUs µs): $e")
            return null
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            try { codec?.release() } catch (_: Exception) {}
            extractor.release()
        }
    }
}
