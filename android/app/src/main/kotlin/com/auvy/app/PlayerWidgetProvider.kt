package com.auvy.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodChannel
import java.net.URL
import kotlin.concurrent.thread

/**
 * Bridge between the Flutter engine and the home-screen player widget.
 *
 * Dart → widget: AuvyAudioHandler pushes now-playing state over the
 * "com.auvy.app/widget" channel; it lands in [handleUpdate], is persisted to
 * SharedPreferences (so the widget renders sanely after reboot/process death),
 * and re-renders every widget instance.
 *
 * Widget → Dart: the LIKE button posts back through the same channel
 * ([invokeToggleLike]). The engine is alive whenever music plays (audio_service
 * keeps it up), which is the only time liking the current track means anything.
 * Transport buttons don't need the engine at all — they go through the media
 * session's MediaButtonReceiver like any headset button.
 */
object WidgetBridge {
    @Volatile var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    private const val PREFS = "auvy_widget_state"

    // Last fetched artwork, keyed by its source URL/path — RemoteViews need a
    // Bitmap, and we only ever show one track's art at a time.
    @Volatile private var artKey: String? = null
    @Volatile private var artBitmap: Bitmap? = null

    fun invokeToggleLike() {
        val ch = channel ?: return
        main.post { ch.invokeMethod("toggleLike", null) }
    }

    fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun artFor(key: String?): Bitmap? =
        if (!key.isNullOrEmpty() && key == artKey) artBitmap else null

    fun handleUpdate(context: Context, args: Map<*, *>) {
        val image = args["image"] as? String ?: ""
        prefs(context).edit()
            .putString("title", args["title"] as? String ?: "")
            .putString("artist", args["artist"] as? String ?: "")
            .putString("image", image)
            .putBoolean("isPlaying", args["isPlaying"] as? Boolean ?: false)
            .putBoolean("isLiked", args["isLiked"] as? Boolean ?: false)
            .putBoolean("hasSong", args["hasSong"] as? Boolean ?: false)
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
                        // Widgets don't need more than ~256px; large bitmaps can
                        // blow the RemoteViews transaction limit.
                        val scale = 256f / maxOf(raw.width, raw.height)
                        artBitmap = if (scale < 1f) {
                            Bitmap.createScaledBitmap(
                                raw,
                                (raw.width * scale).toInt().coerceAtLeast(1),
                                (raw.height * scale).toInt().coerceAtLeast(1),
                                true,
                            )
                        } else raw
                        artKey = image
                    }
                } catch (_: Exception) {
                    // Keep the old art; the launcher icon is the final fallback.
                }
                main.post { PlayerWidgetProvider.renderAll(context) }
            }
        }
        PlayerWidgetProvider.renderAll(context)
    }
}

/** Stock-media-player style widget: artwork, title/artist, prev/play/next + like. */
class PlayerWidgetProvider : AppWidgetProvider() {

    companion object {
        // internal, not private: WidgetActionReceiver below reads them.
        internal const val ACTION_PREV = "com.auvy.app.widget.PREV"
        internal const val ACTION_TOGGLE = "com.auvy.app.widget.TOGGLE"
        internal const val ACTION_NEXT = "com.auvy.app.widget.NEXT"
        internal const val ACTION_LIKE = "com.auvy.app.widget.LIKE"

        fun renderAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, PlayerWidgetProvider::class.java))
            for (id in ids) render(context, mgr, id)
        }

        private fun render(context: Context, mgr: AppWidgetManager, id: Int) {
            val prefs = WidgetBridge.prefs(context)
            val hasSong = prefs.getBoolean("hasSong", false)
            val title = prefs.getString("title", "") ?: ""
            val artist = prefs.getString("artist", "") ?: ""
            val isPlaying = prefs.getBoolean("isPlaying", false)
            val isLiked = prefs.getBoolean("isLiked", false)

            val views = RemoteViews(context.packageName, R.layout.widget_player)
            views.setTextViewText(R.id.widget_title, if (hasSong) title else "Auvy")
            views.setTextViewText(
                R.id.widget_artist,
                if (hasSong) artist else "Tap to start listening")
            views.setImageViewResource(
                R.id.widget_play_pause,
                if (isPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play)
            views.setImageViewResource(
                R.id.widget_like,
                if (isLiked) R.drawable.ic_liked else R.drawable.ic_notliked)

            val art = WidgetBridge.artFor(prefs.getString("image", ""))
            if (art != null) {
                views.setImageViewBitmap(R.id.widget_art, art)
            } else {
                views.setImageViewResource(R.id.widget_art, R.mipmap.ic_launcher)
            }

            views.setOnClickPendingIntent(R.id.widget_prev, broadcast(context, ACTION_PREV, 1))
            views.setOnClickPendingIntent(R.id.widget_play_pause, broadcast(context, ACTION_TOGGLE, 2))
            views.setOnClickPendingIntent(R.id.widget_next, broadcast(context, ACTION_NEXT, 3))
            views.setOnClickPendingIntent(R.id.widget_like, broadcast(context, ACTION_LIKE, 4))

            // Artwork/text area opens the app.
            val open = Intent(context, MainActivity::class.java)
            views.setOnClickPendingIntent(
                R.id.widget_open_area,
                PendingIntent.getActivity(
                    context, 0, open,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))

            mgr.updateAppWidget(id, views)
        }

        private fun broadcast(context: Context, action: String, req: Int): PendingIntent {
            // Targets WidgetActionReceiver, NOT this class.
            //
            // An AppWidgetProvider MUST be exported to receive APPWIDGET_UPDATE
            // from the system, and an exported receiver accepts EXPLICIT
            // intents from any app on the device, whatever its intent-filter
            // says. So while PREV/TOGGLE/NEXT/LIKE were never advertised, any
            // installed app could still fire them: skip the track, toggle
            // playback, or flip a like on the listener's library.
            //
            // A PendingIntent created by this app can target a NON-exported
            // receiver perfectly well, so the actions move somewhere only we can
            // reach while the widget keeps working exactly as before.
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
                PlayerWidgetProvider.sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            PlayerWidgetProvider.ACTION_NEXT ->
                PlayerWidgetProvider.sendMediaKey(context, KeyEvent.KEYCODE_MEDIA_NEXT)
            PlayerWidgetProvider.ACTION_LIKE -> WidgetBridge.invokeToggleLike()
        }
    }
}
