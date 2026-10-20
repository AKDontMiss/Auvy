package com.auvy.app

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.sqrt

/**
 * How loud the music is right now, for the player cover's glow ("With the music"
 * and "Bright" in Appearance). The glow used to read a value nothing ever set,
 * so it never moved.
 *
 * Sits in the player's own audio chain (see NativePlayerManager's renderers
 * factory) and passes every buffer through untouched. The system Visualizer
 * would need the microphone permission; this needs none. It measures only while
 * [enabled] (the player page is on screen with a glow that follows the music):
 * otherwise each buffer is a plain copy.
 */
class LevelMeterAudioProcessor : BaseAudioProcessor() {

    /** Set from the method channel; read on the playback thread. */
    @Volatile var enabled = false

    /** RMS of the first channel of the latest buffer, 0..1. */
    @Volatile var level = 0f

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        // 16-bit and float PCM are measured; anything else (encoded passthrough)
        // leaves the processor inactive, and the chain skips it.
        return if (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT ||
            inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) inputAudioFormat
        else AudioProcessor.AudioFormat.NOT_SET
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        if (enabled) measure(inputBuffer)
        val out = replaceOutputBuffer(remaining)
        out.put(inputBuffer)
        out.flip()
    }

    private fun measure(buffer: ByteBuffer) {
        val format = inputAudioFormat
        val view = buffer.duplicate().order(ByteOrder.nativeOrder())
        val start = view.position()
        val end = view.limit()
        val channels = max(1, format.channelCount)
        var sum = 0.0
        var count = 0
        if (format.encoding == C.ENCODING_PCM_16BIT) {
            // First channel, every second frame: plenty for a light at 20 fps.
            val step = 2 * channels * 2
            var i = start
            while (i + 1 < end) {
                val s = view.getShort(i) / 32768.0
                sum += s * s
                count++
                i += step
            }
        } else {
            val step = 4 * channels * 2
            var i = start
            while (i + 3 < end) {
                val s = view.getFloat(i).toDouble()
                sum += s * s
                count++
                i += step
            }
        }
        if (count > 0) level = sqrt(sum / count).toFloat()
    }

    override fun onFlush() {
        level = 0f
    }

    override fun onReset() {
        level = 0f
    }
}
