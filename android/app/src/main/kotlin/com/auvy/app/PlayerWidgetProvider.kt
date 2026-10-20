package com.auvy.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.SizeF
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URL
import kotlin.concurrent.thread

/**
 * Bridge between the Flutter engine and the home-screen player widget.
 *
 * Dart → widget: AuvyAudioHandler pushes now-playing state over the
 * "com.auvy.app/widget" channel; it lands in [handleUpdate], is persisted to
 * SharedPreferences (so the widget renders sanely after reboot/process death),
 * and re-renders every widget instance and the Quick Settings tile.
 *
 * Widget → Dart: the LIKE button posts back through the same channel
 * ([invokeToggleLike]); play/pause goes through AuvyCommands. Previous and next
 * go through the media session's MediaButtonReceiver like any headset button.
 */
object WidgetBridge {
    @Volatile var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    private const val PREFS = "auvy_widget_state"
    private const val ART_FILE = "widget_art.png"

    // The current track's artwork, rounded, keyed by its source URL/path —
    // RemoteViews need a Bitmap, and only one track's art is ever shown. Also
    // kept on disk, so the widget still has it after the process is gone.
    @Volatile private var artKey: String? = null
    @Volatile private var artBitmap: Bitmap? = null

    /** Moves the widgets' progress bars while a song plays and this process lives. */
    @Volatile private var appContext: Context? = null
    private val progressTicker = object : Runnable {
        override fun run() {
            val ctx = appContext ?: return
            if (!isReallyPlaying(ctx)) return
            // With the screen off nobody sees the bar, and each partial update makes
            // the launcher redraw: skipped until the screen is on again (the next
            // tick, at most five seconds later, catches it up).
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
            if (pm?.isInteractive != false) PlayerWidgetProvider.updateProgress(ctx)
            main.postDelayed(this, 5_000L)
        }
    }

    private fun restartTicker(context: Context) {
        appContext = context.applicationContext
        main.removeCallbacks(progressTicker)
        if (isReallyPlaying(context)) main.postDelayed(progressTicker, 5_000L)
    }

    fun invokeToggleLike() {
        val ch = channel ?: return
        main.post { ch.invokeMethod("toggleLike", null) }
    }

    fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun artFor(context: Context, key: String?): Bitmap? {
        if (key.isNullOrEmpty()) return null
        if (key == artKey && artBitmap != null) return artBitmap
        // After a restart: the copy on disk, if it is this track's.
        if (prefs(context).getString("artKey", null) != key) return null
        return try {
            BitmapFactory.decodeFile(File(context.filesDir, ART_FILE).path)?.also {
                artBitmap = it
                artKey = key
            }
        } catch (_: Exception) {
            null
        }
    }

    fun handleUpdate(context: Context, args: Map<*, *>) {
        val image = args["image"] as? String ?: ""
        prefs(context).edit()
            .putString("title", args["title"] as? String ?: "")
            .putString("artist", args["artist"] as? String ?: "")
            .putString("image", image)
            .putBoolean("isPlaying", args["isPlaying"] as? Boolean ?: false)
            .putBoolean("isLiked", args["isLiked"] as? Boolean ?: false)
            .putBoolean("hasSong", args["hasSong"] as? Boolean ?: false)
            .apply {
                (args["accent"] as? Number)?.let { putInt("accent", it.toInt()) }
            }
            .putString("context", args["context"] as? String ?: "")
            .putLong("positionMs", (args["positionMs"] as? Number)?.toLong() ?: 0L)
            .putLong("durationMs", (args["durationMs"] as? Number)?.toLong() ?: 0L)
            .putLong("sampledAtMs", (args["sampledAtMs"] as? Number)?.toLong() ?: System.currentTimeMillis())
            .putString("upNext", ((args["upNext"] as? List<*>) ?: emptyList<Any>()).joinToString("\n"))
            .apply()

        if (image.isNotEmpty() && image != artKey) {
            // Fetch artwork off the main thread, then re-render with it.
            thread(name = "auvy-widget-art") {
                try {
                    val raw: Bitmap? = if (image.startsWith("http")) {
                        URL(image).openStream().use { BitmapFactory.decodeStream(it) }
                    } else {
                        BitmapFactory.decodeFile(image.removePrefix("file://"))
                    }
                    if (raw != null) {
                        // 200px is plenty for a 112dp cover, and the four sized layouts
                        // travel in one update, which has a size limit.
                        val rounded = roundedSquare(raw, 200, 0.16f)
                        artBitmap = rounded
                        artKey = image
                        val tint = coverTint(raw)
                        try {
                            File(context.filesDir, ART_FILE).outputStream().use {
                                rounded.compress(Bitmap.CompressFormat.PNG, 100, it)
                            }
                        } catch (_: Exception) {}
                        prefs(context).edit().putString("artKey", image).putInt("tint", tint).apply()
                    }
                } catch (_: Exception) {
                    // Keep the previous art; the launcher icon is the final fallback.
                }
                main.post { PlayerWidgetProvider.renderAll(context) }
            }
        }
        PlayerWidgetProvider.renderAll(context)
        MixesWidgetProvider.renderAll(context)
        PlaybackTileService.requestUpdate(context)
        PlayerWidgetProvider.scheduleStaleCheck(context)
        restartTicker(context)
    }

    /// Playing, unless the state says so for longer than the song lasts: the
    /// app can't say it stopped when its process is killed, and then the song's
    /// end is the latest "playing" can still be true.
    fun isReallyPlaying(context: Context): Boolean {
        val p = prefs(context)
        if (!p.getBoolean("isPlaying", false) || !p.getBoolean("hasSong", false)) return false
        val duration = p.getLong("durationMs", 0L)
        val sampledAt = p.getLong("sampledAtMs", 0L)
        if (duration <= 0L || sampledAt <= 0L) return true
        val remaining = duration - p.getLong("positionMs", 0L)
        return System.currentTimeMillis() < sampledAt + remaining + 20_000L
    }

    /// Where the song is now, in ms: the last position plus the time since, while playing.
    fun elapsedMs(context: Context, playing: Boolean): Long {
        val p = prefs(context)
        val position = p.getLong("positionMs", 0L)
        val duration = p.getLong("durationMs", 0L)
        if (!playing) return position
        val now = position + (System.currentTimeMillis() - p.getLong("sampledAtMs", System.currentTimeMillis()))
        return if (duration > 0) minOf(now, duration) else now
    }

    /** A centre-cropped square, scaled to [size] px, with rounded corners. */
    private fun roundedSquare(src: Bitmap, size: Int, radiusFraction: Float): Bitmap {
        val side = minOf(src.width, src.height)
        val square = Bitmap.createBitmap(src, (src.width - side) / 2, (src.height - side) / 2, side, side)
        val scaled = Bitmap.createScaledBitmap(square, size, size, true)
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        val r = size * radiusFraction
        Canvas(out).drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), r, r, paint)
        return out
    }

    /**
     * The cover's colour, darkened for the card behind white text: the same idea
     * as the app's "Cover colour" mini-player. Averaged over a small copy, then
     * held to a dark, moderately saturated shade so a white or neon cover can't
     * wash out the controls.
     */
    private fun coverTint(src: Bitmap): Int {
        val tiny = Bitmap.createScaledBitmap(src, 8, 8, true)
        var r = 0L; var g = 0L; var b = 0L
        for (x in 0 until 8) for (y in 0 until 8) {
            val c = tiny.getPixel(x, y)
            r += Color.red(c); g += Color.green(c); b += Color.blue(c)
        }
        val hsv = FloatArray(3)
        Color.RGBToHSV((r / 64).toInt(), (g / 64).toInt(), (b / 64).toInt(), hsv)
        hsv[1] = hsv[1].coerceIn(0.15f, 0.65f)
        hsv[2] = 0.26f
        return Color.HSVToColor(hsv)
    }
}

/**
 * The home-screen player widget, in the app's look: a card tinted from the
 * cover, rounded artwork, the accent colour on the play button. Two layouts:
 * a one-row strip and, from two rows tall, a larger card with the like button.
 */
class PlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        // internal, not private: WidgetActionReceiver below reads them.
        internal const val ACTION_PREV = "com.auvy.app.widget.PREV"
        internal const val ACTION_TOGGLE = "com.auvy.app.widget.TOGGLE"
        internal const val ACTION_NEXT = "com.auvy.app.widget.NEXT"
        internal const val ACTION_LIKE = "com.auvy.app.widget.LIKE"

        /** Each size's layout, smallest first (the launcher takes the largest that fits). */
        private val LAYOUTS = linkedMapOf(
            SizeF(110f, 110f) to R.layout.widget_player_small,
            SizeF(200f, 50f) to R.layout.widget_player,
            SizeF(200f, 105f) to R.layout.widget_player_large,
            SizeF(200f, 230f) to R.layout.widget_player_xl,
        )

        /** Before Android 12 the size has to be read and the layout chosen here. */
        private fun layoutFor(options: Bundle?): Int {
            val w = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 250
            val h = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 110
            return when {
                w < 200 -> R.layout.widget_player_small
                h >= 230 -> R.layout.widget_player_xl
                h >= 105 -> R.layout.widget_player_large
                else -> R.layout.widget_player
            }
        }

        /** The card colour with nothing to tint it: the app's sheet colour. */
        private const val SURFACE = 0xFF17171C.toInt()
        private const val DEFAULT_ACCENT = 0xFF53B1E1.toInt()

        fun renderAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, PlayerWidgetProvider::class.java))
            for (id in ids) render(context, mgr, id)
        }

        private fun render(context: Context, mgr: AppWidgetManager, id: Int) {
            val views = if (Build.VERSION.SDK_INT >= 31) {
                // The launcher picks the layout that fits the size the widget is now:
                // the iPhone's small, medium and large, plus a one-row strip.
                RemoteViews(LAYOUTS.mapValues { build(context, it.value) })
            } else {
                build(context, layoutFor(mgr.getAppWidgetOptions(id)))
            }
            mgr.updateAppWidget(id, views)
        }

        private fun build(context: Context, layout: Int): RemoteViews {
            val prefs = WidgetBridge.prefs(context)
            val hasSong = prefs.getBoolean("hasSong", false)
            val title = prefs.getString("title", "") ?: ""
            val artist = prefs.getString("artist", "") ?: ""
            val isPlaying = WidgetBridge.isReallyPlaying(context)
            val isLiked = prefs.getBoolean("isLiked", false)
            val accent = prefs.getInt("accent", DEFAULT_ACCENT)
            val art = if (hasSong) WidgetBridge.artFor(context, prefs.getString("image", "")) else null
            val tint = if (art != null) prefs.getInt("tint", SURFACE) else SURFACE

            val views = RemoteViews(context.packageName, layout)
            views.setInt(R.id.widget_bg, "setColorFilter", tint)
            views.setTextViewText(R.id.widget_title, if (hasSong) title else "Auvy")
            views.setTextViewText(
                R.id.widget_artist,
                if (hasSong) artist else "Tap to start listening")
            if (art != null) {
                views.setImageViewBitmap(R.id.widget_art, art)
            } else {
                views.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
            }

            // Play: the accent-filled circle, with a glyph that stays readable on it.
            views.setInt(R.id.widget_play_bg, "setColorFilter", accent)
            views.setImageViewResource(
                R.id.widget_play_glyph,
                if (isPlaying) R.drawable.ic_widget_pause else R.drawable.ic_widget_play)
            views.setInt(R.id.widget_play_glyph, "setColorFilter", glyphOn(accent))
            views.setContentDescription(R.id.widget_play, if (isPlaying) "Pause" else "Play")

            views.setImageViewResource(
                R.id.widget_like,
                if (isLiked) R.drawable.ic_widget_liked else R.drawable.ic_widget_like)
            views.setInt(R.id.widget_like, "setColorFilter", if (isLiked) accent else 0xD9FFFFFF.toInt())
            views.setContentDescription(R.id.widget_like, if (isLiked) "Remove from Liked Songs" else "Like")
            // What each size shows, as on iOS: the small one has play only, the
            // medium and large ones the full row; the strip has no room for extras.
            val small = layout == R.layout.widget_player_small
            val strip = layout == R.layout.widget_player
            val full = !small && !strip
            views.setViewVisibility(R.id.widget_like, if (hasSong && full) View.VISIBLE else View.GONE)
            val transport = if (hasSong && !small) View.VISIBLE else if (small) View.GONE else View.INVISIBLE
            views.setViewVisibility(R.id.widget_prev, transport)
            views.setViewVisibility(R.id.widget_next, transport)

            // "Playing from …".
            val contextLabel = prefs.getString("context", "") ?: ""
            views.setTextViewText(R.id.widget_context, contextLabel.uppercase())
            views.setTextColor(R.id.widget_context, accent)
            views.setViewVisibility(
                R.id.widget_context, if (hasSong && !strip && contextLabel.isNotEmpty()) View.VISIBLE else View.GONE)

            // Progress and times. The clock ticks on its own; the bar is moved every
            // few seconds while playing (WidgetBridge's ticker) and on every push.
            val duration = prefs.getLong("durationMs", 0L)
            val showProgress = hasSong && !strip && duration > 0
            views.setViewVisibility(R.id.widget_progress, if (showProgress) View.VISIBLE else View.GONE)
            if (showProgress) {
                val elapsed = WidgetBridge.elapsedMs(context, isPlaying)
                views.setProgressBar(R.id.widget_progress, 1000, (elapsed * 1000 / duration).toInt().coerceIn(0, 1000), false)
                if (Build.VERSION.SDK_INT >= 31) {
                    views.setColorStateList(R.id.widget_progress, "setProgressTintList",
                        android.content.res.ColorStateList.valueOf(accent))
                }
            }
            val showTimes = showProgress && full
            if (showTimes) {
                val elapsed = WidgetBridge.elapsedMs(context, isPlaying)
                views.setChronometer(R.id.widget_time, android.os.SystemClock.elapsedRealtime() - elapsed, null, isPlaying)
                views.setTextViewText(R.id.widget_total, clock(duration))
            }
            views.setViewVisibility(R.id.widget_time, if (showTimes) View.VISIBLE else View.GONE)
            views.setViewVisibility(R.id.widget_total, if (showTimes) View.VISIBLE else View.GONE)

            // Up Next, on the large one.
            val next = (prefs.getString("upNext", "") ?: "").split("\n").filter { it.isNotBlank() }
            val rows = intArrayOf(R.id.widget_next1, R.id.widget_next2, R.id.widget_next3)
            val showNext = layout == R.layout.widget_player_xl
            views.setViewVisibility(R.id.widget_next_header, if (showNext) View.VISIBLE else View.GONE)
            views.setTextColor(R.id.widget_next_header, accent)
            for ((i, row) in rows.withIndex()) {
                val line = next.getOrNull(i)
                if (showNext && line != null) {
                    views.setTextViewText(row, "${i + 1}   $line")
                    views.setViewVisibility(row, View.VISIBLE)
                } else {
                    views.setViewVisibility(row, View.GONE)
                }
            }
            if (showNext && next.isEmpty()) {
                views.setTextViewText(
                    R.id.widget_next1,
                    if (hasSong) "Recommendations carry on after this song" else "Your next songs appear here")
                views.setViewVisibility(R.id.widget_next1, View.VISIBLE)
            }

            views.setOnClickPendingIntent(R.id.widget_prev, broadcast(context, ACTION_PREV, 1))
            // With Auvy running, play/pause is a command to it. With Auvy closed, the
            // button opens the app and carries on where it stopped: a media key into a
            // closed app would start only a screenless engine that can't play.
            views.setOnClickPendingIntent(
                R.id.widget_play,
                if (AuvyCommands.isLive && hasSong) broadcast(context, ACTION_TOGGLE, 2)
                else AuvyCommands.commandPendingIntent(context, 42, "play", "from" to "widget"))
            views.setOnClickPendingIntent(R.id.widget_next, broadcast(context, ACTION_NEXT, 3))
            views.setOnClickPendingIntent(R.id.widget_like, broadcast(context, ACTION_LIKE, 4))

            // Artwork and text open where the song is playing from: its playlist,
            // or its album (the main layout decides). With no song, just the app.
            val openTarget =
                if (hasSong) AuvyCommands.commandPendingIntent(context, 43, "openNowPlaying", "from" to "widget")
                else PendingIntent.getActivity(
                    context, 0, Intent(context, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            views.setOnClickPendingIntent(R.id.widget_open_area, openTarget)
            views.setOnClickPendingIntent(R.id.widget_art, openTarget)
            return views
        }

        /**
         * Moves just the progress bars, without re-sending the artwork: a partial
         * update with one action per layout. Called every few seconds while playing.
         */
        internal fun updateProgress(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val prefs = WidgetBridge.prefs(context)
            val duration = prefs.getLong("durationMs", 0L)
            if (duration <= 0L || !prefs.getBoolean("hasSong", false)) return
            val elapsed = WidgetBridge.elapsedMs(context, WidgetBridge.isReallyPlaying(context))
            val value = (elapsed * 1000 / duration).toInt().coerceIn(0, 1000)
            fun partial(layout: Int) = RemoteViews(context.packageName, layout).apply {
                setProgressBar(R.id.widget_progress, 1000, value, false)
            }
            for (id in ids) {
                try {
                    val views = if (Build.VERSION.SDK_INT >= 31) RemoteViews(LAYOUTS.mapValues { partial(it.value) })
                    else partial(layoutFor(mgr.getAppWidgetOptions(id)))
                    mgr.partiallyUpdateAppWidget(id, views)
                } catch (_: Exception) {}
            }
        }

        private fun clock(ms: Long): String {
            val total = ms / 1000
            return "%d:%02d".format(total / 60, total % 60)
        }

        /**
         * Redraws the widget just after the song should have ended. If Auvy was
         * killed while playing, nobody else would, and it would go on showing a
         * pause button and a running clock. An inexact alarm is enough, and it is
         * replaced by each new push.
         */
        internal fun scheduleStaleCheck(context: Context) {
            try {
                val am = context.getSystemService(android.app.AlarmManager::class.java) ?: return
                val ids = AppWidgetManager.getInstance(context)
                    .getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java))
                val intent = Intent(context, PlayerWidgetProvider::class.java)
                    .setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                val pending = PendingIntent.getBroadcast(
                    context, 44, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                am.cancel(pending)
                val p = WidgetBridge.prefs(context)
                if (ids.isEmpty() || !p.getBoolean("isPlaying", false)) return
                val duration = p.getLong("durationMs", 0L)
                if (duration <= 0L) return
                val endsAt = p.getLong("sampledAtMs", System.currentTimeMillis()) +
                    (duration - p.getLong("positionMs", 0L))
                am.set(android.app.AlarmManager.RTC, endsAt + 25_000L, pending)
            } catch (_: Exception) {
                // No alarm: the widget is corrected by the next push instead.
            }
        }

        /** Black on a light accent, white on a dark one. */
        private fun glyphOn(accent: Int): Int {
            val luminance = (0.299 * Color.red(accent) + 0.587 * Color.green(accent) +
                0.114 * Color.blue(accent)) / 255
            return if (luminance > 0.62) 0xFF101014.toInt() else Color.WHITE
        }

        private fun broadcast(context: Context, action: String, req: Int): PendingIntent {
            // Button intents target WidgetActionReceiver, not this class. An
            // AppWidgetProvider must be exported to receive APPWIDGET_UPDATE, and an
            // exported receiver accepts explicit intents from any app, so any installed
            // app could have skipped tracks or toggled likes. A PendingIntent from this
            // app can target a non-exported receiver, so the actions live there.
            val i = Intent(context, WidgetActionReceiver::class.java).setAction(action)
            return PendingIntent.getBroadcast(
                context, req, i,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }

        /**
         * Route transport through audio_service's exported MediaButtonReceiver —
         * the exact path a headset button takes, so debounce/lifecycle handling
         * in the Dart handler applies unchanged.
         */
        internal fun sendMediaKey(context: Context, keyCode: Int) {
            for (action in intArrayOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
                val i = Intent(Intent.ACTION_MEDIA_BUTTON)
                    .setComponent(ComponentName(
                        context, "com.ryanheise.audioservice.MediaButtonReceiver"))
                    .putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(action, keyCode))
                context.sendBroadcast(i)
            }
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, mgr, id)
    }

    /** Resized: below Android 12 the layout is chosen here, by height. */
    override fun onAppWidgetOptionsChanged(
        context: Context, mgr: AppWidgetManager, id: Int, newOptions: Bundle?,
    ) {
        render(context, mgr, id)
    }

    // No custom-action handling here any more. See the note in broadcast().
    // This receiver now does only what an AppWidgetProvider must do, which is
    // the whole reason it is allowed to be exported.
}

/**
 * The widget's buttons, on a receiver nothing outside the app can reach.
 *
 * Declared `android:exported="false"`, so the system will not deliver an intent
 * here from another package. The widget's own PendingIntents still work: they
 * are minted by this app and carry its identity.
 */
class WidgetActionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            PlayerWidgetProvider.ACTION_PREV ->
                PlayerWidgetProvider.sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS)
            PlayerWidgetProvider.ACTION_TOGGLE ->
                if (AuvyCommands.isLive) {
                    AuvyCommands.run("togglePlay", mapOf("from" to "widget"))
                } else {
                    // Rendered while Auvy was running, tapped after it closed. Opening
                    // the app is the only way to really play; if the system won't let a
                    // background receiver open it, the old media key is the fallback.
                    try {
                        context.startActivity(AuvyCommands.commandIntent(context, "play", "from" to "widget"))
                    } catch (_: Exception) {
                        PlayerWidgetProvider.sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                    }
                }
            PlayerWidgetProvider.ACTION_NEXT ->
                PlayerWidgetProvider.sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            PlayerWidgetProvider.ACTION_LIKE -> WidgetBridge.invokeToggleLike()
            MixesWidgetProvider.ACTION_MIX -> {
                val mix = intent.getStringExtra(MixesWidgetProvider.EXTRA_MIX) ?: return
                val shuffle = intent.getBooleanExtra(MixesWidgetProvider.EXTRA_SHUFFLE, false)
                if (AuvyCommands.isLive) {
                    AuvyCommands.run("playCollection", mapOf("id" to mix, "shuffle" to shuffle, "from" to "widget"))
                } else {
                    try {
                        context.startActivity(AuvyCommands.commandIntent(
                            context, "playCollection", "id" to mix, "shuffle" to shuffle, "from" to "widget"))
                    } catch (_: Exception) {}
                }
            }
        }
    }
}
