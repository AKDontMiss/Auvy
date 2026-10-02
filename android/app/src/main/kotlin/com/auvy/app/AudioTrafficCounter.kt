package com.auvy.app

import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import java.util.concurrent.atomic.AtomicLong

/**
 * How many bytes of audio the player has downloaded over the network in
 * this process.
 *
 * ExoPlayer fetches streams through media3's own data sources, so they never
 * pass the Dart HTTP interceptor that feeds Settings → Storage & data. This
 * counter fills that gap.
 *
 * Only `isNetwork` transfers are counted; reads served from the play-cache
 * raise the same callback but cost no data.
 *
 * Dart pulls the value when the Storage & data screen opens, rather than being
 * pushed every transfer, which would wake the Dart isolate constantly. Both
 * this count and Dart's totals last for the process's lifetime, so nothing is
 * lost between pulls. (The "data:" lines in the activity log therefore show
 * audio only after that screen has been opened.)
 */
@UnstableApi
object AudioTrafficCounter : TransferListener {
    private val networkBytes = AtomicLong(0)

    /// Cumulative network bytes since this process started.
    fun total(): Long = networkBytes.get()

    /// Bytes since the last drain, then reset to zero. The Dart side adds up what
    /// it receives, so each call must only report new bytes. getAndSet is atomic,
    /// so nothing transferred in between is lost.
    fun drain(): Long = networkBytes.getAndSet(0)

    override fun onBytesTransferred(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
        bytesTransferred: Int,
    ) {
        if (isNetwork && bytesTransferred > 0) {
            networkBytes.addAndGet(bytesTransferred.toLong())
        }
    }

    // The interface's other three carry no byte count, so there is nothing to
    // do in them. Present because it is an interface, not because they matter.
    override fun onTransferInitializing(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
    ) = Unit

    override fun onTransferStart(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
    ) = Unit

    override fun onTransferEnd(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
    ) = Unit
}
