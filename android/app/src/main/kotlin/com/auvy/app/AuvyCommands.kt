package com.auvy.app

import android.app.PendingIntent
import android.app.SearchManager
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.URL
import kotlin.concurrent.thread

/**
 * The Android side of `com.auvy.app/commands` (see app_commands.dart).
 *
 * Commands arrive from the icon's long-press menu, pinned playlist shortcuts,
 * the Quick Settings tile, the widget, voice search, and links shared or opened
 * into Auvy. Each is a name and arguments. One that arrives before Dart is
 * listening (a cold start from a shortcut) is held until Dart says "ready".
 */
object AuvyCommands {
    const val ACTION_COMMAND = "com.auvy.app.COMMAND"
    const val EXTRA_COMMAND = "auvy.command"
    private const val ARG_PREFIX = "auvy.arg."
    /** Set on an intent once handled, so a recreated activity doesn't run it twice. */
    private const val EXTRA_HANDLED = "auvy.command.handled"

    private const val PREFS = "auvy_commands"

    /** The commands an intent may carry: those [commandIntent] is used for. */
    private val INTENT_COMMANDS = setOf("play", "playCollection", "playPlaylist", "openSearch", "openNowPlaying")
    private val INTENT_ARGS = listOf("id" to String::class, "name" to String::class, "shuffle" to Boolean::class, "from" to String::class)
    private val INTENT_SOURCES = setOf("shortcut", "widget", "tile")

    @Volatile private var channel: MethodChannel? = null
    @Volatile private var messenger: BinaryMessenger? = null
    @Volatile private var dartReady = false
    private val pending = mutableListOf<Map<String, Any?>>()
    private val main = Handler(Looper.getMainLooper())

    /** Whether Dart is up in this process and taking commands. */
    val isLive: Boolean get() = channel != null && dartReady

    fun attach(context: Context, messenger: BinaryMessenger) {
        // The engine is cached by audio_service and outlives the activity, so a
        // recreated activity re-registers on the SAME engine, whose Dart side has
        // already said ready once and won't again.
        if (this.messenger !== messenger) dartReady = false
        this.messenger = messenger
        val ch = MethodChannel(messenger, "com.auvy.app/commands")
        val app = context.applicationContext
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    dartReady = true
                    val out = synchronized(pending) { pending.toList().also { pending.clear() } }
                    result.success(out)
                    // The widget's play button opens the app while Auvy is closed;
                    // now that it's running, it can be a command again.
                    PlayerWidgetProvider.renderAll(app)
                    MixesWidgetProvider.renderAll(app)
                }
                "setPlaylists" -> {
                    val names = (call.argument<List<String>>("names") ?: emptyList())
                    app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                        .putString("playlists", names.joinToString("\n")).apply()
                    result.success(null)
                }
                "clipboardHint" -> {
                    // Whether a link was copied, from the clip's DESCRIPTION only:
                    // reading the clip itself makes Android 12+ announce that Auvy
                    // pasted. The URL score needs Android 12; before that there's
                    // no offer (sharing to Auvy works on every version).
                    val cm = app.getSystemService(android.content.ClipboardManager::class.java)
                    val desc = try { cm?.primaryClipDescription } catch (_: Exception) { null }
                    var hasUrl = false
                    if (desc != null && android.os.Build.VERSION.SDK_INT >= 31 &&
                        desc.classificationStatus == android.content.ClipDescription.CLASSIFICATION_COMPLETE) {
                        hasUrl = desc.getConfidenceScore(android.view.textclassifier.TextClassifier.TYPE_URL) > 0.5f
                    }
                    result.success(mapOf("changeCount" to (desc?.timestamp ?: 0L), "hasURL" to hasUrl))
                }
                "openLinkSettings" -> {
                    // Android 12+ has a screen for exactly this; before it, the
                    // app's details page holds "Open by default".
                    val pkg = android.net.Uri.parse("package:${app.packageName}")
                    val intent = if (android.os.Build.VERSION.SDK_INT >= 31)
                        Intent(android.provider.Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS, pkg)
                    else Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg)
                    result.success(try {
                        app.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
                    } catch (_: Exception) { false })
                }
                "pinPlaylist" -> {
                    val name = call.argument<String>("name") ?: ""
                    val image = call.argument<String>("image") ?: ""
                    result.success(pinPlaylist(app, name, image))
                }
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    /** Sends a command to Dart now, or holds it until Dart is ready. */
    fun run(command: String, args: Map<String, Any?>) {
        val entry = mapOf("command" to command, "args" to args)
        main.post {
            val ch = channel
            if (ch != null && dartReady) {
                ch.invokeMethod("run", entry)
            } else {
                synchronized(pending) { pending.add(entry) }
            }
        }
    }

    /**
     * Takes the command out of an intent that opened MainActivity, if it carries
     * one: a shortcut, a share, a music link or a voice search.
     */
    fun handleIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(EXTRA_HANDLED, false)) return
        // Reopened from Recents: the original intent comes back, and running its
        // command again would be wrong.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        var handled = true
        when (intent.action) {
            ACTION_COMMAND -> {
                // MainActivity is the launcher activity, so it is exported and any
                // app can send it this action. Only what Auvy's own shortcuts,
                // widgets and tile send gets through, with only their arguments.
                val command = intent.getStringExtra(EXTRA_COMMAND)
                if (command == null || command !in INTENT_COMMANDS) {
                    handled = false
                } else {
                    val args = mutableMapOf<String, Any?>("from" to "shortcut")
                    val extras = intent.extras
                    for ((name, kind) in INTENT_ARGS) {
                        val key = ARG_PREFIX + name
                        if (extras == null || !extras.containsKey(key)) continue
                        @Suppress("DEPRECATION")
                        val value = extras.get(key)
                        when {
                            kind == Boolean::class && value is Boolean -> args[name] = value
                            kind == String::class && value is String && value.length <= 200 -> args[name] = value
                        }
                    }
                    if (args["from"] !in INTENT_SOURCES) args["from"] = "shortcut"
                    run(command, args)
                }
            }
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                // A share carries a link and maybe a sentence; nothing longer is a link.
                if (text.isNullOrBlank() || text.length > 4096) handled = false
                else run("openLink", mapOf("url" to text, "from" to "share"))
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data
                if (data == null || (data.scheme != "https" && data.scheme != "http") ||
                    data.toString().length > 4096) handled = false
                else run("openLink", mapOf("url" to data.toString(), "from" to "link"))
            }
            MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH -> {
                val query = intent.getStringExtra(SearchManager.QUERY).orEmpty()
                // An empty query means "play something": carry on where it stopped.
                if (query.isBlank()) run("play", mapOf("from" to "voice"))
                else run("searchPlay", mapOf("query" to query, "from" to "voice"))
            }
            else -> handled = false
        }
        if (handled) intent.putExtra(EXTRA_HANDLED, true)
    }

    /** An intent that opens Auvy and runs [command] there. */
    fun commandIntent(context: Context, command: String, vararg args: Pair<String, Any>): Intent =
        Intent(context, MainActivity::class.java)
            .setAction(ACTION_COMMAND)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_COMMAND, command)
            .apply {
                for ((k, v) in args) {
                    when (v) {
                        is String -> putExtra(ARG_PREFIX + k, v)
                        is Boolean -> putExtra(ARG_PREFIX + k, v)
                        is Int -> putExtra(ARG_PREFIX + k, v)
                    }
                }
            }

    fun commandPendingIntent(context: Context, requestCode: Int, command: String, vararg args: Pair<String, Any>): PendingIntent =
        PendingIntent.getActivity(
            context, requestCode, commandIntent(context, command, *args),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    // ── The icon's long-press menu ──

    /**
     * The four shortcuts on the icon's long-press menu. Dynamic rather than static
     * (shortcuts.xml) because the launcher entry is one of several icon aliases,
     * and static shortcuts would have to be declared on every one of them.
     */
    fun publishShortcuts(context: Context) {
        try {
            val sm = context.getSystemService(ShortcutManager::class.java) ?: return
            fun shortcut(id: String, label: String, long: String, icon: Int, intent: Intent, rank: Int) =
                ShortcutInfo.Builder(context, id)
                    .setShortLabel(label)
                    .setLongLabel(long)
                    .setIcon(Icon.createWithResource(context, icon))
                    .setIntent(intent)
                    .setRank(rank)
                    .build()
            sm.dynamicShortcuts = listOf(
                shortcut("liked", "Liked Songs", "Shuffle Liked Songs", R.drawable.ic_shortcut_liked,
                    commandIntent(context, "playCollection", "id" to "liked", "shuffle" to true), 0),
                shortcut("weekly", "Weekly Discovery", "Play Weekly Discovery", R.drawable.ic_shortcut_discovery,
                    commandIntent(context, "playCollection", "id" to "weekly"), 1),
                shortcut("top50", "My Top 50", "Play My Top 50", R.drawable.ic_shortcut_top,
                    commandIntent(context, "playCollection", "id" to "top50"), 2),
                shortcut("search", "Search", "Search Auvy", R.drawable.ic_shortcut_search,
                    commandIntent(context, "openSearch"), 3),
            )
        } catch (e: Exception) {
            android.util.Log.w("AuvyCommands", "shortcuts not published: ${e.message}")
        }
    }

    /**
     * Puts a playlist on the home screen as its own icon; one tap plays it. The
     * launcher asks the user to confirm. Uses the playlist's cover when it can be
     * read, otherwise a playlist glyph. False when the launcher can't pin.
     */
    private fun pinPlaylist(context: Context, name: String, image: String): Boolean {
        if (name.isBlank()) return false
        val sm = context.getSystemService(ShortcutManager::class.java) ?: return false
        if (!sm.isRequestPinShortcutSupported) return false
        thread(name = "auvy-pin-playlist") {
            val icon = coverIcon(image) ?: Icon.createWithResource(context, R.drawable.ic_shortcut_playlist)
            val info = ShortcutInfo.Builder(context, "playlist:${name.hashCode()}")
                .setShortLabel(name.take(24))
                .setLongLabel("Play $name")
                .setIcon(icon)
                .setIntent(commandIntent(context, "playPlaylist", "name" to name))
                .build()
            main.post {
                try { sm.requestPinShortcut(info, null) } catch (e: Exception) {
                    android.util.Log.w("AuvyCommands", "pin failed: ${e.message}")
                }
            }
        }
        return true
    }

    /** The cover as an adaptive icon: square, inset into the launcher's safe zone. */
    private fun coverIcon(image: String): Icon? {
        if (image.isBlank()) return null
        return try {
            val raw: Bitmap = (if (image.startsWith("http")) {
                URL(image).openStream().use { BitmapFactory.decodeStream(it) }
            } else {
                BitmapFactory.decodeFile(image.removePrefix("file://"))
            }) ?: return null
            // An adaptive icon is 108 units with the middle 72 always visible; the
            // cover fills it, so nothing important is cropped by any mask shape.
            val size = 216
            val side = minOf(raw.width, raw.height)
            val square = Bitmap.createBitmap(raw, (raw.width - side) / 2, (raw.height - side) / 2, side, side)
            val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            Canvas(out).drawBitmap(Bitmap.createScaledBitmap(square, size, size, true), 0f, 0f, null)
            Icon.createWithAdaptiveBitmap(out)
        } catch (_: Exception) {
            null
        }
    }
}
