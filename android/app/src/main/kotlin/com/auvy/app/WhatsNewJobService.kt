package com.auvy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

/**
 * What's New's check with Auvy closed, the Android side of AuvyWhatsNewBackground
 * in AuvySystemChannels.swift.
 *
 * A periodic JobScheduler job (twice a day, on a network) that runs without Dart:
 * it reads the list Dart wrote (files/whats_new/watch.json), asks the iTunes
 * catalogue the same questions, applies the same rules as whats_new_logic.dart,
 * posts notifications, and leaves what it found in files/whats_new/bg.json for
 * the app to take in. The keys and wording must stay in step with Dart's.
 */
class WhatsNewJobService : JobService() {

    @Volatile private var worker: Thread? = null

    override fun onStartJob(params: JobParameters): Boolean {
        worker = Thread {
            try {
                check(applicationContext)
            } catch (e: Exception) {
                Log.w(TAG, "background check failed: $e")
            }
            jobFinished(params, false)
        }.also { it.start() }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        worker?.interrupt()
        return true
    }

    companion object {
        private const val TAG = "AuvyWhatsNew"
        private const val JOB_ID = 4720
        const val CHANNEL = "auvy_whats_new"
        const val EXTRA_OPEN = "auvy_open_whats_new"

        /** Turns the job on or off. Called by Dart through MainActivity. */
        fun setEnabled(context: Context, on: Boolean, dataSaver: Boolean) {
            val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
            if (!on) {
                scheduler.cancel(JOB_ID)
                return
            }
            val info = JobInfo.Builder(JOB_ID, ComponentName(context, WhatsNewJobService::class.java))
                .setRequiredNetworkType(
                    if (dataSaver) JobInfo.NETWORK_TYPE_UNMETERED else JobInfo.NETWORK_TYPE_ANY)
                .setPeriodic(12 * 3600_000L, 3 * 3600_000L)
                .setPersisted(true)
                .build()
            // Re-scheduling an identical job would restart its period, so only when
            // something changed.
            val existing = scheduler.getPendingJob(JOB_ID)
            if (existing == null || existing.networkType != info.networkType) scheduler.schedule(info)
        }

        private fun dir(context: Context) = File(context.filesDir, "whats_new")

        private fun read(file: File): JSONObject? =
            try { if (file.exists()) JSONObject(file.readText()) else null } catch (_: Exception) { null }

        /** The same loose comparison as normalizeArtistName in Dart. */
        fun normalize(name: String): String {
            var n = name.lowercase()
            if (n.endsWith(" - topic")) n = n.dropLast(8)
            return n.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.joinToString(" ")
        }

        private fun get(path: String): JSONArray {
            val conn = URL("https://itunes.apple.com/$path").openConnection() as HttpURLConnection
            return try {
                conn.connectTimeout = 15_000
                conn.readTimeout = 15_000
                if (conn.responseCode != 200) JSONArray()
                else JSONObject(conn.inputStream.bufferedReader().readText()).optJSONArray("results")
                    ?: JSONArray()
            } catch (_: Exception) {
                JSONArray()
            } finally {
                conn.disconnect()
            }
        }

        private fun ms(raw: String?): Long? =
            try { if (raw.isNullOrEmpty()) null else Instant.parse(raw).toEpochMilli() } catch (_: Exception) { null }

        private fun large(url: String) = url.replace(Regex("/\\d+x\\d+bb\\."), "/600x600bb.")

        private data class Found(
            val key: String, val kind: String, val title: String, val source: String,
            val label: String, val image: String, val dateMs: Long, val target: String,
        )

        fun check(context: Context) {
            val d = dir(context)
            val watch = read(File(d, "watch.json")) ?: return
            if (!watch.optBoolean("enabled")) return
            val previous = read(File(d, "bg.json")) ?: JSONObject()
            val now = System.currentTimeMillis()
            val last = maxOf(watch.optLong("lastCheckMs"), previous.optLong("checkedMs"))
            // The app checked recently, or this did: nothing can be new enough yet.
            if (now - last < 3 * 3600_000L) return

            val notified = mutableSetOf<String>()
            for (arr in listOf(watch.optJSONArray("notified"), previous.optJSONArray("notified"))) {
                if (arr != null) for (i in 0 until arr.length()) notified.add(arr.optString(i))
            }
            val from = now - 3 * 24 * 3600_000L
            val due = mutableListOf<Found>()

            // Releases: each artist entry is followed by that artist's releases.
            val byId = mutableMapOf<Long, Pair<String, String>>()
            watch.optJSONArray("artists")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val a = arr.optJSONObject(i) ?: continue
                    byId[a.optLong("id")] = a.optString("name") to a.optString("appId")
                }
            }
            for (chunk in byId.keys.chunked(15)) {
                if (Thread.currentThread().isInterrupted) return
                var current: Triple<Long, String, String>? = null
                val results = get("lookup?id=${chunk.joinToString(",")}&entity=album&sort=recent&limit=15")
                for (i in 0 until results.length()) {
                    val r = results.optJSONObject(i) ?: continue
                    if (r.optString("wrapperType") == "artist") {
                        val id = r.optLong("artistId", -1)
                        current = byId[id]?.let { Triple(id, it.first, it.second) }
                        continue
                    }
                    val artist = current ?: continue
                    if (r.optString("wrapperType") != "collection") continue
                    val cid = r.optLong("collectionId", -1)
                    val name = r.optString("collectionName")
                    val date = ms(r.optString("releaseDate")) ?: continue
                    if (cid < 0 || name.isEmpty() || date < from || date > now) continue
                    if (name.lowercase().contains("video album") || "rel:$cid" in notified) continue
                    val credited = r.optString("artistName")
                    val own = r.optLong("artistId", -2) == artist.first
                    if (!own && !" ${normalize(credited)} ".contains(" ${normalize(artist.second)} ")) continue
                    var title = name.trim()
                    val count = r.optInt("trackCount")
                    var label = if (count in 1..3) "Single" else "Album"
                    for ((suffix, l) in listOf(" - Single" to "Single", " - EP" to "EP")) {
                        if (title.endsWith(suffix)) {
                            title = title.dropLast(suffix.length).trim()
                            label = l
                        }
                    }
                    notified.add("rel:$cid")
                    due.add(Found("rel:$cid", "release", title,
                        artist.second, label,
                        large(r.optString("artworkUrl100")), date,
                        artist.third.ifEmpty { artist.second }))
                }
            }

            // Episodes.
            val shows = mutableMapOf<Long, Pair<String, String>>()
            watch.optJSONArray("podcasts")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val p = arr.optJSONObject(i) ?: continue
                    shows[p.optLong("id")] = p.optString("name") to p.optString("feed")
                }
            }
            for (chunk in shows.keys.chunked(10)) {
                if (Thread.currentThread().isInterrupted) return
                val results = get("lookup?id=${chunk.joinToString(",")}&entity=podcastEpisode&limit=2")
                for (i in 0 until results.length()) {
                    val r = results.optJSONObject(i) ?: continue
                    if (r.optString("wrapperType") != "podcastEpisode") continue
                    val show = shows[r.optLong("collectionId", -1)] ?: continue
                    val tid = r.optLong("trackId", -1)
                    val title = r.optString("trackName")
                    val date = ms(r.optString("releaseDate")) ?: continue
                    if (tid < 0 || title.isEmpty() || date < from || date > now || "ep:$tid" in notified) continue
                    notified.add("ep:$tid")
                    due.add(Found("ep:$tid", "episode", title, show.first, "Episode",
                        large(r.optString("artworkUrl600")), date, show.second))
                }
            }

            // The same wording and grouping as notificationsFor in Dart.
            fun headline(f: Found) =
                if (f.kind == "episode") "New episode of ${f.source}"
                else "New ${f.label.lowercase()} from ${f.source}"
            if (due.size in 1..3) {
                for (f in due) post(context, f.key, headline(f), f.title)
            } else if (due.size > 3) {
                val sources = due.map { it.source }.distinct()
                val episodes = due.count { it.kind == "episode" }
                val what = when (episodes) {
                    0 -> "new releases"
                    due.size -> "new episodes"
                    else -> "new releases and episodes"
                }
                val names = if (sources.size <= 2) sources.joinToString(" and ")
                else "${sources.take(2).joinToString(", ")} and ${sources.size - 2} more"
                post(context, "summary:${due[0].key}", "${due.size} $what", names)
            }

            val found = previous.optJSONArray("found") ?: JSONArray()
            for (f in due) {
                found.put(JSONObject()
                    .put("key", f.key).put("kind", f.kind).put("title", f.title)
                    .put("source", f.source).put("label", f.label).put("image", f.image)
                    .put("dateMs", f.dateMs).put("foundMs", now).put("target", f.target))
            }
            val trimmed = JSONArray()
            for (i in maxOf(0, found.length() - 50) until found.length()) trimmed.put(found.get(i))
            val line = "${byId.size} artist(s), ${shows.size} podcast(s), ${due.size} new"
            val out = JSONObject()
                .put("notified", JSONArray(notified.toList().takeLast(400)))
                .put("found", trimmed)
                .put("checkedMs", now)
                .put("line", line)
            d.mkdirs()
            val tmp = File(d, "bg.json.tmp")
            tmp.writeText(out.toString())
            tmp.renameTo(File(d, "bg.json"))
            Log.i(TAG, "background check: $line")
        }

        /** Posts one notification; a tap opens What's New. */
        fun post(context: Context, id: String, title: String, body: String) {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (!nm.areNotificationsEnabled()) return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "New releases", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = "New music and episodes from what you follow" })
            val tap = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_OPEN, true)
            val pending = PendingIntent.getActivity(
                context, 4721, tap, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val note = Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setGroup("auvy.whatsnew")
                .build()
            nm.notify("whatsnew", id.hashCode(), note)
        }
    }
}
