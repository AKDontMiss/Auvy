package com.auvy.app

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import kotlin.math.min

/**
 * Wraps an upstream HTTP [DataSource] and fetches the resource as a series of
 * small, bounded byte-range requests, stitched into one continuous stream
 * that is transparent to ExoPlayer.
 *
 * Why: googlevideo can return HTTP 403 for large or open-ended `Range:`
 * requests (especially behind VPNs or filtered DNS) while serving small
 * bounded ranges (256 KB works) normally. Chunking the fetch, as yt-dlp and
 * NewPipe do, avoids that.
 *
 * [totalLength] must be the real content length (googlevideo's `clen`) so we
 * know when to stop without an open-ended request.
 */
@UnstableApi
class ChunkedDataSource(
    private val upstream: DataSource,
    initialChunkSize: Long,
    private val totalLength: Long,
) : DataSource {

    // Mutable: starts at the smaller of the requested size and the size last
    // proven to work this session (see sessionChunkSize). Halved toward
    // MIN_CHUNK whenever the CDN rejects a range with that size (403/400 etc.).
    // This adapts to gated / throttled egress paths without giving up the speed
    // of large chunks on healthy networks — and, crucially, only pays the
    // shrink-retry cost ONCE per session instead of on every open/seek.
    private var chunkSize: Long = min(initialChunkSize, sessionChunkSize)

    private var uri: Uri? = null
    private var position: Long = 0        // absolute position of the next byte to read
    private var bytesRemaining: Long = 0  // bytes still owed to ExoPlayer for this open()
    private var chunkRemaining: Long = 0  // bytes left in the current upstream chunk
    private var chunkOpen = false
    private var freshChunk = false        // guards against an empty-chunk infinite loop

    /// How many times the CURRENT range has come back empty. Reset on any real
    /// byte and on every open(). See the empty-chunk branch in [read].
    private var emptyChunkRetries = 0

    companion object {
        private const val MIN_CHUNK = 256L * 1024   // proven-served floor
        private const val MAX_OPEN_RETRIES = 4

        /// How many bytes the priming request asks for. Two, not one: some CDNs
        /// answer a single-byte range oddly, and two costs nothing.
        private const val PRIME_BYTES = 2L

        /// URLs already touched from byte 0 this session. See [primeFromStart].
        /// A LinkedHashSet so the oldest entry can be evicted in insertion order.
        private val primedUris = LinkedHashSet<String>()

        /// Bound on [primedUris]. Stream URLs are long, and a long session
        /// re-resolves many of them; 64 covers a full queue without growing.
        private const val MAX_PRIMED_URIS = 64

        // Bounded re-requests for a range that answers successfully but with an
        // EMPTY body. Three attempts over ~1.5s: enough to ride out a CDN
        // throttle burst, short enough that a genuinely dead range still surfaces
        // quickly rather than stalling playback.
        private const val MAX_EMPTY_CHUNK_RETRIES = 3
        // How long to keep retrying the SAME range when the fault is a network
        // outage (DNS can't resolve / no route) rather than a CDN rejection. With the
        // screen off, Doze or Wi-Fi power-save can cut the radio mid-stream while the
        // URL is still valid. Waiting here (the loader thread is allowed to block)
        // keeps the current track alive instead of failing and making Dart
        // re-resolve, which would also fail and skip through the queue.
        private const val MAX_NET_WAIT_MS = 60_000L

        // A connectivity fault means "no network right now" (the URL is fine),
        // as opposed to a 403/410 CDN rejection (the URL/range is the problem).
        // Shrinking chunks or re-resolving does nothing for a connectivity fault
        // — only waiting for the radio helps, so it takes the patient path.
        fun isConnectivityError(t: Throwable?): Boolean {
            var cause: Throwable? = t
            var depth = 0
            while (cause != null && depth < 8) {
                when (cause) {
                    is java.net.UnknownHostException,
                    is java.net.ConnectException,
                    is java.net.NoRouteToHostException,
                    is java.net.SocketTimeoutException,
                    is java.net.PortUnreachableException -> return true
                    is java.net.SocketException -> return true
                }
                val msg = cause.message?.lowercase() ?: ""
                if (msg.contains("unable to resolve host") ||
                    msg.contains("failed to connect") ||
                    msg.contains("network is unreachable") ||
                    msg.contains("no address associated") ||
                    msg.contains("connection reset") ||
                    msg.contains("connection abort") ||
                    msg.contains("software caused connection abort")
                ) return true
                cause = cause.cause
                depth++
            }
            return false
        }
        // Largest chunk size proven to work on the current egress path this
        // session. Ratchets DOWN when a size 403s so every subsequent
        // stream/seek/track starts at the known-good size immediately and never
        // re-pays the 403 shrink-retry cost. The floor (MIN_CHUNK) is itself a
        // proven-working size, so staying there for the session is safe; a
        // process restart re-probes from the top.
        @Volatile
        @JvmStatic
        var sessionChunkSize: Long = Long.MAX_VALUE
    }

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        uri = dataSpec.uri
        position = dataSpec.position
        bytesRemaining = if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
            dataSpec.length
        } else {
            (totalLength - position).coerceAtLeast(0L)
        }
        emptyChunkRetries = 0 // per-open budget, not per-source
        // Touch byte 0 before a mid-file range on a URL that hasn't served anything
        // yet: googlevideo can refuse a mid-file Range on such a "virgin" URL. This
        // matters for seeks and for the first range after the 1 MiB prewarm. It costs
        // two bytes per URL.
        if (position > 0L) primeFromStart()
        openNextChunk()
        return bytesRemaining
    }

    /// Make this URL "legal" for a mid-file range by fetching its first bytes.
    ///
    /// Best-effort and deliberately tiny. If it fails, the real request below
    /// still runs and the existing shrink/retry ladder behaves exactly as before —
    /// this can only add a chance of success, never remove one.
    private fun primeFromStart() {
        val u = uri ?: return
        val key = u.toString()
        synchronized(primedUris) {
            if (!primedUris.add(key)) return // this URL has already served from 0
            // Bounded: stream URLs are long strings and a session can resolve many.
            if (primedUris.size > MAX_PRIMED_URIS) {
                val it = primedUris.iterator()
                if (it.hasNext()) { it.next(); it.remove() }
            }
        }
        try {
            val spec = DataSpec.Builder()
                .setUri(u)
                .setPosition(0)
                .setLength(PRIME_BYTES)
                .build()
            upstream.open(spec)
            // Actually read, so the request completes rather than being abandoned
            // mid-flight — an unread open is not proof the URL served anything.
            val buf = ByteArray(PRIME_BYTES.toInt())
            upstream.read(buf, 0, buf.size)
            android.util.Log.i("AuvyPlayer", "primed url from byte 0 for mid-file range")
        } catch (e: Exception) {
            android.util.Log.w(
                "AuvyPlayer", "prime-from-start failed (${e.javaClass.simpleName}) — continuing")
        } finally {
            try { upstream.close() } catch (_: Exception) {}
        }
    }

    private fun openNextChunk() {
        if (chunkOpen) {
            upstream.close()
            chunkOpen = false
        }
        if (min(chunkSize, bytesRemaining) <= 0L) {
            chunkRemaining = 0L
            return
        }

        var attempt = 0
        var netWaitElapsedMs = 0L
        while (true) {
            val want = min(chunkSize, bytesRemaining)
            val spec = DataSpec.Builder()
                .setUri(uri!!)
                .setPosition(position)
                .setLength(want)
                .build()
            try {
                val resolved = upstream.open(spec)
                chunkRemaining = if (resolved == C.LENGTH_UNSET.toLong() || resolved <= 0L) want else resolved
                chunkOpen = true
                freshChunk = true
                return
            } catch (e: Exception) {
                // A range of this size was rejected (commonly 403/400 on gated
                // egress). Shrink and retry — large chunks are an optimisation,
                // small bounded ranges are the proven-working fallback.
                try { upstream.close() } catch (_: Exception) {}
                chunkOpen = false

                // Log the rejection details here, on the first failure of each open(): this
                // retry loop absorbs 403s before they ever reach NativePlayerManager's load
                // error policy, so its "403 DETAIL" dump would never see them. Only the first
                // failure is logged so a burst of retries doesn't bury it.
                if (attempt == 0) {
                    try {
                        val u = uri
                        fun q(k: String) = u?.getQueryParameter(k)
                        android.util.Log.w(
                            "AuvyPlayer",
                            "403 CHUNK pos=$position want=$want remaining=$bytesRemaining " +
                                "chunkSize=$chunkSize itag=${q("itag")} clen=${q("clen")} " +
                                "urlRange=${q("range")} hasPot=${q("pot") != null} " +
                                "hasN=${q("n") != null} expire=${q("expire")} " +
                                "now=${System.currentTimeMillis() / 1000} " +
                                "host=${u?.host} err=${e.javaClass.simpleName}"
                        )
                    } catch (_: Exception) {
                        // Never let the diagnostic break the retry it is describing.
                    }
                }
                // Network outage (Doze / Wi-Fi power-save): the URL is fine but the radio is
                // asleep. Shrinking chunks or re-resolving can't help, so keep retrying the
                // same range until connectivity returns (see MAX_NET_WAIT_MS).
                if (isConnectivityError(e)) {
                    if (netWaitElapsedMs >= MAX_NET_WAIT_MS) {
                        android.util.Log.w(
                            "AuvyPlayer",
                            "network still down after ${netWaitElapsedMs}ms (${e.message}) — surfacing for Dart hold"
                        )
                        throw e
                    }
                    // Sleep in ≤1s slices so a load cancellation (seek / track
                    // change interrupts the loader thread) is honored promptly.
                    val slice = 1000L
                    android.util.Log.w(
                        "AuvyPlayer",
                        "network outage (${e.message}); waiting for radio, same range retry (${netWaitElapsedMs}ms/${MAX_NET_WAIT_MS}ms)"
                    )
                    try { Thread.sleep(slice) } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt(); throw e
                    }
                    netWaitElapsedMs += slice
                    continue  // do NOT spend the 403 shrink/backoff budget on an outage
                }
                // A URL past its own `expire=` deadline can NEVER recover — every
                // retry at every size 403s. Surface immediately so the Dart side
                // resolves a fresh URL, instead of burning ~10-30s of silence in
                // doomed shrink/backoff retries (the "stops mid-track" stall).
                if (urlExpired()) {
                    android.util.Log.w(
                        "AuvyPlayer",
                        "stream URL past its expire= deadline — failing fast for a fresh resolve"
                    )
                    throw e
                }
                if (chunkSize > MIN_CHUNK && attempt < MAX_OPEN_RETRIES) {
                    chunkSize = (chunkSize / 2).coerceAtLeast(MIN_CHUNK)
                    // Remember the smaller size for the rest of the session so
                    // later opens/seeks/tracks skip straight to a working size.
                    if (chunkSize < sessionChunkSize) sessionChunkSize = chunkSize
                    android.util.Log.w(
                        "AuvyPlayer",
                        "chunk open failed (${e.message}); shrinking chunk to $chunkSize and retrying"
                    )
                    attempt++
                    continue
                }
                // At the floor size: transient CDN rate-gates (403 bursts on a
                // throttled IP) often clear within a second. Re-try the SAME
                // range briefly before surfacing — a full player error costs a
                // Dart-side re-resolve + re-buffer (an audible multi-second
                // gap), while this quiet retry usually rides the burst out.
                // Runs on ExoPlayer's loader thread, never the main thread.
                if (attempt < MAX_OPEN_RETRIES + 2) {
                    val backoffMs = 400L * (attempt - MAX_OPEN_RETRIES + 2).coerceAtLeast(1)
                    android.util.Log.w(
                        "AuvyPlayer",
                        "floor-size chunk 403'd (${e.message}); retrying same range in ${backoffMs}ms"
                    )
                    try { Thread.sleep(backoffMs) } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt(); throw e
                    }
                    attempt++
                    continue
                }
                throw e  // out of retries — surface to ExoPlayer
            }
        }
    }

    // googlevideo URLs carry their expiry as `expire=<epoch seconds>`.
    private fun urlExpired(): Boolean = try {
        val exp = uri?.getQueryParameter("expire")?.toLongOrNull()
        exp != null && System.currentTimeMillis() / 1000 > exp
    } catch (_: Exception) {
        false // opaque/odd URI — can't tell, let the normal retry path decide
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        while (bytesRemaining > 0L) {
            if (chunkRemaining <= 0L) {
                openNextChunk()
                if (chunkRemaining <= 0L) break
            }
            val toRead = min(length.toLong(), chunkRemaining).toInt()
            val n = upstream.read(buffer, offset, toRead)
            if (n == C.RESULT_END_OF_INPUT) {
                val wasFresh = freshChunk
                chunkRemaining = 0L
                if (wasFresh) {
                    // A chunk opened fine but returned zero bytes while bytes are still owed.
                    // Ending the read here would return RESULT_END_OF_INPUT, which ExoPlayer
                    // treats as the end of the track, so it would stop mid-song and skip.
                    // Re-request the same range a bounded number of times instead.
                    if (emptyChunkRetries < MAX_EMPTY_CHUNK_RETRIES) {
                        emptyChunkRetries++
                        val backoffMs = 250L * emptyChunkRetries
                        android.util.Log.w(
                            "AuvyPlayer",
                            "empty chunk at pos=$position with $bytesRemaining bytes still owed " +
                                "— re-requesting same range in ${backoffMs}ms " +
                                "($emptyChunkRetries/$MAX_EMPTY_CHUNK_RETRIES)"
                        )
                        try { Thread.sleep(backoffMs) } catch (_: InterruptedException) {
                            Thread.currentThread().interrupt()
                            break
                        }
                        continue
                    }
                    // Out of retries: throw rather than returning end-of-input, because the
                    // stream has NOT finished. The load policy then retries, and if that fails
                    // the Dart side recovers the same track (restart or cached copy) instead of
                    // advancing the queue. Logged natively and forwarded to Dart so early ends
                    // show up in exported logs.
                    val msg = "$bytesRemaining bytes never delivered at pos=$position " +
                        "after $emptyChunkRetries empty-chunk retries"
                    android.util.Log.e("AuvyPlayer", "TRACK ENDING EARLY: $msg")
                    try {
                        NativePlayerManager.noteToDart("stream ended early — $msg")
                    } catch (_: Exception) {
                    }
                    throw java.io.IOException("empty chunk: $msg")
                }
                continue
            }
            freshChunk = false
            // Real bytes arrived, so whatever caused the empty response has passed.
            emptyChunkRetries = 0
            position += n
            chunkRemaining -= n
            bytesRemaining -= n
            return n
        }
        if (bytesRemaining > 0L) {
            val msg = "Premature end of input: $bytesRemaining bytes still owed at pos=$position"
            android.util.Log.e("AuvyPlayer", msg)
            throw java.io.IOException(msg)
        }
        return C.RESULT_END_OF_INPUT
    }

    override fun getUri(): Uri? = uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        if (chunkOpen) {
            upstream.close()
            chunkOpen = false
        }
    }
}
