package com.auvy.app

import android.content.Intent
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * Quick-settings tile: identify whatever is playing RIGHT NOW, without leaving
 * the app you are in.
 *
 * WHY A TILE AND NOT THE HOME-BUTTON GESTURE. The obvious ask is to copy what
 * Google does — hold home, get a panel that can search the audio or the screen.
 * That gesture belongs to the device's DEFAULT ASSISTANT, and Android does not
 * expose it to ordinary apps; only an app registered as the assistant can answer
 * it. A quick-settings tile is the sanctioned equivalent and costs the same one
 * gesture: pull the shade down while Instagram is playing, tap, done. It is also
 * exactly how Google's own Sound Search tile works.
 *
 * The machinery for this already existed — AudioCaptureService's ARMED mode holds
 * a MediaProjection so repeated captures need no further consent, writes the PCM
 * to a pending file, and MainLayout._maybeIdentifyPendingCapture identifies it the
 * next time Auvy is opened. The only missing piece was something to press.
 *
 * Arming happens IN THE APP, once, because MediaProjection consent must come from
 * a visible activity. Until then the tile shows as unavailable rather than
 * pretending to work and failing silently at the moment the user needs it.
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

        // MICROPHONE, NOT SCREEN CAPTURE. Verified against the two apps that do
        // this well: Shazam's own AutoTaggingTileService holds
        // FOREGROUND_SERVICE_MICROPHONE and RECORD_AUDIO, and requests no
        // MediaProjection at all. Recognition tiles do not need screen capture.
        //
        // The mic hears the phone's own speaker, so whatever another app is playing
        // out loud is identifiable with NO consent dialog and nothing shared. That
        // is the whole point: one tap, an answer.
        //
        // RECORD_AUDIO is a runtime permission and a service cannot ask for it, so
        // when it is missing the app is opened to request it once — the only case
        // that still needs Auvy, and it never recurs.
        // VIA AN ACTIVITY, NOT DIRECTLY. Starting the mic service from here is
        // refused: a tile runs with the app in the BACKGROUND, and RECORD_AUDIO is a
        // while-in-use permission that needs an eligible foreground state. That is
        // what produced "Android refused the microphone" even with the permission
        // granted. TileCaptureActivity is invisible, becomes foreground for an
        // instant, starts the service, and finishes. See its class note.
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
     * Open the invisible consent activity and collapse the shade.
     *
     * THE PENDING-INTENT OVERLOAD IS MANDATORY ON ANDROID 14+. The old
     * `startActivityAndCollapse(Intent)` does not merely warn there — it THROWS
     * UnsupportedOperationException. Wrapped in a try/catch, that turned into a
     * tile that visibly did nothing at all when tapped, with the reason buried in
     * a log line. Take the platform's word for it and pass a PendingIntent.
     */
    private fun launchToGrantMic() {
        val consent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            // Ask on arrival. Opening the app without this left the user staring at
            // Home with no idea why, and the tile would refuse again on the next
            // tap — a loop with no way out from the shade.
            .putExtra(MainActivity.EXTRA_ASK_MIC, true)
        try {
            if (android.os.Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(
                    android.app.PendingIntent.getActivity(
                        this,
                        0,
                        consent,
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                            android.app.PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(consent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "could not ask for consent: ${e.javaClass.simpleName} ${e.message}")
        }
    }

    /**
     * THIS TILE IS A BUTTON, NOT A SWITCH. IT HAS NO ON STATE.
     *
     * It was written with ACTIVE-when-armed / INACTIVE-otherwise, and that model
     * cannot hold: the thing it reported was `AudioCaptureService.isArmed`, which
     * is a MediaProjection held in memory. Android reclaims the process whenever it
     * likes, the projection dies with it, and the tile silently flipped back to
     * off — so "enabled" was a claim it could not keep, and every reclaim looked
     * like the tile breaking. (Before that it used STATE_UNAVAILABLE for "not
     * armed", which is worse still: unavailable tiles are not clickable at all, so
     * the one state needing a tap was the one state that could not receive one.)
     *
     * A single neutral state is honest and simpler. Every tap does the same thing —
     * capture, asking for consent first if the grant has lapsed — so there is
     * nothing to enable, nothing to get stuck, and no state to disagree with
     * reality. The consent dialog reappearing after a process death is Android's
     * requirement, not a mode the user has to manage.
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
         * A TILE CANNOT BE UPDATED FROM OUTSIDE ITSELF. `qsTile` is only valid
         * between onStartListening and onStopListening, so the capture service holds
         * no handle it could use to switch the tile off when it finishes.
         * requestListeningState is the sanctioned way in: it triggers
         * onStartListening, and refresh() then reads `isCapturing` and settles on
         * whichever state is actually true.
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
