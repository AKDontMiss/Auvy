package com.auvy.app

import android.content.Intent
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * Quick-settings tile: identify whatever is playing right now without
 * leaving the app you are in.
 *
 * A tile rather than the "hold home" gesture, because that gesture belongs to
 * the device's default assistant and ordinary apps can't claim it. A tile is
 * the sanctioned equivalent (it's how Google's own Sound Search tile works).
 *
 * A tap records a short clip from the microphone via [TileCaptureActivity]
 * and AudioCaptureService; the clip is written to a pending file that
 * MainLayout._maybeIdentifyPendingCapture identifies the next time Auvy is
 * opened.
 */
class RecognizeTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        if (AudioCaptureService.isCapturing) {
            Log.i(TAG, "already capturing — ignoring tile tap")
            return
        }

        // Microphone, not screen capture: the mic hears the phone's own speaker, so
        // whatever another app is playing out loud can be identified with no
        // consent dialog (this is how Shazam's tile works too).
        //
        // Started via an activity rather than directly: a tile runs with the app in
        // the background, and RECORD_AUDIO is a while-in-use permission, so Android
        // refuses to start the mic service from here. TileCaptureActivity is
        // invisible, briefly brings the app to the foreground (asking for the
        // permission the first time), starts the service, and finishes.
        try {
            val launch = Intent(this, TileCaptureActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(
                    android.app.PendingIntent.getActivity(
                        this,
                        1,
                        launch,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                            android.app.PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(launch)
            }
            Log.i(TAG, "tile tapped — launching capture activity")
            // Light up NOW rather than waiting for the service to report back.
            // Eight seconds of a tile that looks untouched is indistinguishable
            // from a tile that did nothing, which is exactly how this felt.
            refresh(listening = true)
        } catch (e: Exception) {
            Log.w(TAG, "tile capture failed: ${e.javaClass.simpleName} ${e.message}")
            refresh()
        }
    }

    /**
     * The tile is a button, not a switch: it has a single neutral state (plus
     * "listening" while a capture runs). Every tap does the same thing, so there
     * is nothing to enable and no state that can drift out of sync with reality.
     */
    /// [listening] forces the lit state for the tap that just started a capture,
    /// because `isCapturing` is set on the service's thread and may not be true yet
    /// the instant onClick returns.
    private fun refresh(listening: Boolean = false) {
        val tile = qsTile ?: return
        try {
            val busy = listening || AudioCaptureService.isCapturing
            tile.state = if (busy) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            tile.label = "Identify song"
            tile.icon = Icon.createWithResource(this, android.R.drawable.ic_btn_speak_now)
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                tile.subtitle = if (busy) "Listening…" else "Tap to identify"
            }
            tile.updateTile()
        } catch (e: Exception) {
            Log.w(TAG, "tile refresh failed: ${e.message}")
        }
    }


    companion object {
        private const val TAG = "AuvyCapture"

        /**
         * Ask the system to bind this tile briefly so it re-reads its state.
         *
         * `qsTile` is only valid between onStartListening and onStopListening, so
         * the capture service can't update the tile directly. requestListeningState
         * triggers onStartListening, and refresh() then reads `isCapturing`.
         */
        fun requestRefresh(context: android.content.Context) {
            try {
                requestListeningState(
                    context,
                    android.content.ComponentName(context, RecognizeTileService::class.java),
                )
            } catch (e: Exception) {
                Log.w(TAG, "tile refresh request failed: ${e.message}")
            }
        }
    }
}
