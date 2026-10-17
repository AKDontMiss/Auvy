package com.auvy.app

import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * The Quick Settings play/pause tile, Android's counterpart of the iPhone's
 * Control Center button.
 *
 * Shows what's playing (title, and the artist as the subtitle on Android 10+)
 * from the state the widget already keeps, and lights up while music plays.
 * A tap toggles playback through AuvyCommands when Auvy is running; with Auvy
 * closed it opens the app and carries on where it stopped.
 */
class PlaybackTileService : TileService() {

    companion object {
        /** Asks the system to refresh the tile; called whenever the widget state changes. */
        fun requestUpdate(context: Context) {
            try {
                requestListeningState(context, ComponentName(context, PlaybackTileService::class.java))
            } catch (_: Exception) {
                // The tile isn't added, or the system refused; nothing to update.
            }
        }
    }

    override fun onStartListening() {
        super.onStartListening()
        render()
    }

    override fun onClick() {
        super.onClick()
        val prefs = WidgetBridge.prefs(this)
        if (AuvyCommands.isLive && prefs.getBoolean("hasSong", false)) {
            AuvyCommands.run("togglePlay", mapOf("from" to "tile"))
            // Shown at once rather than after the round trip through Dart; the next
            // state push corrects it if the command didn't take.
            val playing = !prefs.getBoolean("isPlaying", false)
            prefs.edit().putBoolean("isPlaying", playing).apply()
            render()
            return
        }
        val pending = AuvyCommands.commandPendingIntent(this, 41, "play", "from" to "tile")
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(AuvyCommands.commandIntent(this, "play", "from" to "tile"))
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        val prefs = WidgetBridge.prefs(this)
        val hasSong = prefs.getBoolean("hasSong", false)
        val playing = hasSong && prefs.getBoolean("isPlaying", false)
        val title = prefs.getString("title", "") ?: ""
        val artist = prefs.getString("artist", "") ?: ""
        tile.label = if (hasSong && title.isNotEmpty()) title else "Auvy"
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = when {
                !hasSong -> "Tap to play"
                artist.isNotEmpty() -> artist
                else -> if (playing) "Playing" else "Paused"
            }
        }
        tile.contentDescription = if (playing) "Pause $title" else "Play ${title.ifEmpty { "Auvy" }}"
        tile.icon = Icon.createWithResource(this, if (playing) R.drawable.ic_tile_pause else R.drawable.ic_tile_play)
        tile.state = if (playing) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }
}
