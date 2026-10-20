package com.auvy.app

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Fetches a YouTube song whole to a file before it plays, as the iOS player does
 * (AuvyStreamLoader.downloadToFile): the player then plays the file, its waveform
 * is read from it, and a song heard for a while is kept by copying it
 * (promoteFromPlayCache). The next song is fetched the same way in the current
 * one's last seconds, so it starts from disk.
 *
 * The bytes come through the player's own resolving source without the
 * play-cache: bounded 512 KB requests (googlevideo refuses large ones), the URL
 * refreshed through Dart when it runs out, ContinuousDataSource joining the
 * ranges. A refused URL (403/410) is forgotten so the next attempt resolves a new
 * one; a dropped connection resumes where it stopped, unless the new URL is
 * another format, whose bytes would not continue the ones written. A song is
 * written to `<id>.part` and renamed `<id>.audio` only when whole, so a file
 * under that name is always complete. The newest few are kept; older ones are
 * removed.
 *
 * Each caller says whether it still wants the song. Once none has for a second
 * (the song was skipped, or is no longer next), the fetch stops, as iOS stops a
 * skipped song's download, so a skip costs only what had arrived.
 *
 * A song over about 20 minutes (a mix, a long video) is not fetched: whole, it
 * would keep the listener waiting while it downloads, and no waveform is drawn
 * past 20 minutes anyway. The player streams it instead (iOS can't, which is
 * why it fetches everything).
 */
@OptIn(UnstableApi::class)
object TrackFetcher {
    private const val TAG = "TrackFetcher"
    /** As many as the iOS player keeps: the playing song, the next, and spare. */
    private const val KEEP = 4
    private const val ATTEMPTS = 4
    /** How long no caller may want a song before its fetch stops. */
    private const val DROP_AFTER_MS = 1_000L

    /** About 20 minutes at the highest audio bitrate offered (~160 kbps). */
    private const val LONG_BYTES = 24L * 1024 * 1024

    /** Songs found to be over [LONG_BYTES], so they aren't opened again to learn it. */
    private val long = ConcurrentHashMap.newKeySet<String>()

    /**
     * The current song and the next can be fetched at the same time. The threads
     * end after a minute unused.
     */
    private val executor = ThreadPoolExecutor(2, 2, 60L, TimeUnit.SECONDS, LinkedBlockingQueue())
        .apply { allowCoreThreadTimeOut(true) }

    private class Waiter(val wanted: () -> Boolean, val done: (File?) -> Unit)

    /** Songs being fetched and who is waiting for each. Main thread only. */
    private val inFlight = HashMap<String, MutableList<Waiter>>()

    /** The same waiters' wishes, for the fetching thread to read. */
    private val wishes = ConcurrentHashMap<String, List<() -> Boolean>>()

    @Volatile private var dir: File? = null

    fun setUp(context: Context) {
        if (dir != null) return
        dir = File(context.cacheDir, "auvy-tracks").apply {
            mkdirs()
            // Once per process, before any fetch: a `.part` left by a process that
            // was killed mid-fetch is never finished (a fetch starts its file anew),
            // so it would otherwise stay on disk.
            listFiles { f -> f.name.endsWith(".part") }?.forEach { it.delete() }
        }
    }

    /** The whole fetched file for [videoId], or null. */
    fun fileFor(videoId: String): File? =
        dir?.let { File(it, "$videoId.audio") }?.takeIf { it.isFile && it.length() > 0 }

    /** [videoId]'s fetched file, marked as just used so it is kept, or null. */
    fun take(videoId: String): File? =
        fileFor(videoId)?.also { it.setLastModified(System.currentTimeMillis()) }

    /**
     * Deletes the file the player failed to read, if it is a fetched song, so the
     * next play of it fetches it again instead of failing the same way.
     */
    fun discardIfFetched(uri: Uri?): Boolean {
        val d = dir ?: return false
        val file = uri?.takeIf { it.scheme == "file" }?.path?.let { File(it) } ?: return false
        if (file.parentFile?.canonicalPath != d.canonicalPath || !file.name.endsWith(".audio")) return false
        return file.delete()
    }

    /** Whether [videoId] is known to be too long to fetch (see [LONG_BYTES]). */
    fun isLong(videoId: String) = videoId in long

    /** Whether [videoId] is being fetched now. Main thread only. */
    fun isFetching(videoId: String) = inFlight.containsKey(videoId)

    /**
     * Calls [done] on the main thread with the whole file, or null if it could not
     * be fetched or nobody wanted it any more. A song already fetched answers at
     * once; one being fetched adds [done] to its waiters. [source] opens the song
     * through the resolving source, [expected] is the length of the format being
     * read (0 if not known), [dropUrl] forgets a refused URL, [wanted] says whether
     * this caller still wants the song (read from the fetching thread). Call on
     * the main thread.
     */
    fun fetch(
        videoId: String,
        source: () -> DataSource,
        expected: () -> Long,
        dropUrl: () -> Unit,
        main: Handler,
        wanted: () -> Boolean,
        done: (File?) -> Unit,
    ) {
        take(videoId)?.let { file ->
            done(file)
            return
        }
        if (isLong(videoId)) {
            done(null)
            return
        }
        val waiter = Waiter(wanted, done)
        val waiting = inFlight[videoId]
        if (waiting != null) {
            waiting.add(waiter)
            wishes[videoId] = waiting.map { it.wanted }
            return
        }
        inFlight[videoId] = mutableListOf(waiter)
        wishes[videoId] = listOf(wanted)
        start(videoId, source, expected, dropUrl, main)
    }

    private fun start(videoId: String, source: () -> DataSource, expected: () -> Long, dropUrl: () -> Unit, main: Handler) {
        executor.execute {
            val outcome = download(videoId, source, expected, dropUrl)
            main.post {
                val waiters = inFlight.remove(videoId) ?: return@post
                if (outcome.dropped) {
                    // Wanted again after the fetch decided to stop: fetched afresh for
                    // those who want it now.
                    val still = waiters.filter { it.wanted() }
                    if (still.isNotEmpty()) {
                        inFlight[videoId] = still.toMutableList()
                        wishes[videoId] = still.map { it.wanted }
                        start(videoId, source, expected, dropUrl, main)
                        waiters.filterNot { it in still }.forEach { it.done(null) }
                        return@post
                    }
                }
                wishes.remove(videoId)
                waiters.forEach { it.done(outcome.file) }
            }
        }
    }

    private class Outcome(val file: File?, val dropped: Boolean = false)

    private fun download(videoId: String, source: () -> DataSource, expected: () -> Long, dropUrl: () -> Unit): Outcome {
        val d = dir ?: return Outcome(null)
        val part = File(d, "$videoId.part")
        val whole = File(d, "$videoId.audio")
        part.delete()
        var unwantedSince = 0L
        fun stillWanted(): Boolean {
            if (wishes[videoId]?.any { it() } != false) {
                unwantedSince = 0L
                return true
            }
            val now = SystemClock.elapsedRealtime()
            if (unwantedSince == 0L) unwantedSince = now
            return now - unwantedSince < DROP_AFTER_MS
        }
        fun spec(at: Long) = DataSpec.Builder().setUri(Uri.parse(videoId)).setKey(videoId).setPosition(at).build()
        var written = 0L
        // The length of the format the bytes written so far belong to.
        var length = 0L
        // Stopped because nobody wanted it (not a failure); decided once, so a wish
        // that returns just after can't turn it into one.
        var dropped = false
        for (attempt in 1..ATTEMPTS) {
            if (!stillWanted()) { dropped = true; break }
            val ds = source()
            try {
                ds.open(spec(written))
                // The open resolved the URL, so this is the format now being read.
                val total = expected()
                if (written > 0 && length > 0 && total > 0 && total != length) {
                    Log.w(TAG, "$videoId is another format after a new URL ($length → $total bytes); starting over")
                    ds.close()
                    part.delete()
                    written = 0L
                    ds.open(spec(0L))
                }
                if (total > LONG_BYTES) {
                    if (long.size > 64) long.clear()
                    long.add(videoId)
                    part.delete()
                    Log.i(TAG, "$videoId is ${total / (1024 * 1024)} MB, too long to fetch first; it streams")
                    return Outcome(null)
                }
                if (total > 0) length = total
                FileOutputStream(part, true).use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (!stillWanted()) { dropped = true; break }
                        val n = ds.read(buffer, 0, buffer.size)
                        if (n == C.RESULT_END_OF_INPUT) break
                        out.write(buffer, 0, n)
                        written += n
                    }
                }
                if (dropped) break
                if (length > 0 && written < length) {
                    // Ended short of the song's length: the rest is fetched on the next try.
                    Log.w(TAG, "$videoId ended at $written of $length bytes (try $attempt)")
                    continue
                }
                if (written <= 0 || !part.renameTo(whole)) break
                prune(d, keep = videoId)
                Log.i(TAG, "$videoId fetched whole (${written / 1024} KB)")
                return Outcome(whole)
            } catch (e: HttpDataSource.InvalidResponseCodeException) {
                if (e.responseCode == 403 || e.responseCode == 410) dropUrl()
                Log.w(TAG, "$videoId refused (${e.responseCode}) at $written bytes (try $attempt)")
            } catch (e: IOException) {
                Log.w(TAG, "$videoId interrupted at $written bytes (try $attempt): ${e.message}")
                try { Thread.sleep(1000L * attempt) } catch (_: InterruptedException) { break }
            } finally {
                try { ds.close() } catch (_: Exception) {}
            }
        }
        part.delete()
        if (dropped) {
            Log.i(TAG, "$videoId no longer wanted; stopped at ${written / 1024} KB")
            return Outcome(null, dropped = true)
        }
        Log.w(TAG, "$videoId could not be fetched whole")
        return Outcome(null)
    }

    /** Keeps the newest few fetched songs, and always [keep]. */
    private fun prune(d: File, keep: String) {
        val files = d.listFiles { f -> f.name.endsWith(".audio") }?.sortedByDescending { it.lastModified() } ?: return
        for (f in files.drop(KEEP)) {
            if (f.name != "$keep.audio") f.delete()
        }
    }
}
