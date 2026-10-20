package com.auvy.app

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

/**
 * Joins the bounded ranges the stream resolver hands out back into one stream,
 * so the extractor only ever sees end-of-input at the real end of the file.
 *
 * The resolver caps every open at 512 KB (see createResolvingDataSourceFactory).
 * Each cap used to reach the extractor as end-of-input. In the middle of an
 * element that is an EOFException, which the loader retries from the same byte,
 * so playback carried on. But WebM's reader takes end-of-input at the START of
 * an element as the end of the file, so whenever a 512 KB boundary fell exactly
 * between two elements (about one boundary in 350 for opus audio, so a few songs
 * in a hundred) the song ended there and ExoPlayer moved on to the next one, with
 * no error anywhere.
 *
 * A range that delivered everything its open promised stopped at the cap, not at
 * the end, so the next range is opened here. A range that ends short of its
 * promise, or an empty next range, is the end of the file, as before. Every
 * range still goes through the resolver, so URL refreshes, the play-cache and
 * the 403 handling see exactly the requests they saw before.
 */
@UnstableApi
class ContinuousDataSource(
    private val upstream: DataSource,
    /// The format's whole length for a cache key, or 0 when unknown. Only
    /// reported to the player; whether to keep reading never depends on it.
    private val totalLength: (String) -> Long,
) : DataSource {

    private var spec: DataSpec? = null
    private var position = 0L
    /// Bytes still owed on the player's own request; LENGTH_UNSET means "to the end".
    private var owed = UNSET
    private var rangePromised = UNSET
    private var rangeRead = 0L

    private companion object {
        val UNSET = C.LENGTH_UNSET.toLong()
    }

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        spec = dataSpec
        position = dataSpec.position
        owed = dataSpec.length
        openRange()
        if (dataSpec.length != UNSET) return dataSpec.length
        // Read after the first range: its open may be the resolve that learns the length.
        val total = dataSpec.key?.let(totalLength) ?: 0L
        return if (total > position) total - position else UNSET
    }

    private fun openRange() {
        rangeRead = 0L
        rangePromised = upstream.open(
            spec!!.buildUpon().setPosition(position).setLength(owed).build())
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (owed == 0L) return C.RESULT_END_OF_INPUT
        val want = if (owed == UNSET) length else minOf(length.toLong(), owed).toInt()
        var n = upstream.read(buffer, offset, want)
        if (n == C.RESULT_END_OF_INPUT && endedAtCap()) {
            upstream.close()
            openRange()
            n = upstream.read(buffer, offset, want)
        }
        if (n == C.RESULT_END_OF_INPUT) return n
        position += n
        rangeRead += n
        if (owed != UNSET) owed -= n
        return n
    }

    /// The range delivered all it promised, so it stopped at the resolver's cap
    /// rather than at the end of the file.
    private fun endedAtCap(): Boolean =
        rangeRead > 0L && rangePromised != UNSET && rangeRead >= rangePromised

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        // Always, even after a failed open: the DataSource contract requires it.
        upstream.close()
    }
}
