package com.auvy.app.dsp

import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.AudioProcessor.EMPTY_BUFFER
import java.nio.ByteBuffer
import java.nio.ByteOrder

class NativeDspProcessor : AudioProcessor {
    private var inputFormat = AudioFormat.NOT_SET
    private var outputFormat = AudioFormat.NOT_SET
    private var buffer = EMPTY_BUFFER
    private var outputBuffer = EMPTY_BUFFER
    private var inputEnded = false

    companion object {
        init {
            System.loadLibrary("native_dsp") // Link structural C++ assembly rules
        }
    }

    // Direct interface maps pointing directly down to our fast C++ transformation blocks
    private external fun processVolumeNormalization(buffer: FloatArray, size: Int, targetRms: Float, maxGain: Float, currentGain: FloatArray): Float

    private var sharedGainTracker = floatArrayOf(1.0f)

    override fun configure(inputAudioFormat: AudioFormat): AudioFormat {
        // Intercept standard uncompressed stream blocks and scale formatting layouts safely
        inputFormat = inputAudioFormat
        outputFormat = AudioFormat(inputAudioFormat.sampleRate, inputAudioFormat.channelCount, androidx.media3.common.C.ENCODING_PCM_FLOAT)
        return outputFormat
    }

    override fun isActive(): Boolean = inputFormat != AudioFormat.NOT_SET

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return

        val remainingBytes = inputBuffer.remaining()
        val floatCount = remainingBytes / 4
        
        // Extract raw Float values out of the channel layout
        val floatData = FloatArray(floatCount)
        inputBuffer.order(ByteOrder.nativeOrder()).asFloatBuffer().get(floatData)

        // Pass frame tracking down to your native performance matrices
        processVolumeNormalization(floatData, floatCount, 0.14f, 2.5f, sharedGainTracker)

        // Write the balanced float values directly back to our active output pipeline
        val byteBufferCapacity = floatCount * 4
        if (buffer.capacity() < byteBufferCapacity) {
            buffer = ByteBuffer.allocateDirect(byteBufferCapacity).order(ByteOrder.nativeOrder())
        } else {
            buffer.clear()
        }

        buffer.asFloatBuffer().put(floatData)
        buffer.limit(byteBufferCapacity)
        outputBuffer = buffer
    }

    override fun queueEndOfStream() { inputEnded = true }
    override fun getOutput(): ByteBuffer {
        val output = outputBuffer
        outputBuffer = EMPTY_BUFFER
        return output
    }
    override fun isEnded(): Boolean = inputEnded && outputBuffer == EMPTY_BUFFER
    override fun flush() { outputBuffer = EMPTY_BUFFER; inputEnded = false }
    override fun reset() { flush(); inputFormat = AudioFormat.NOT_SET; outputFormat = AudioFormat.NOT_SET }
}