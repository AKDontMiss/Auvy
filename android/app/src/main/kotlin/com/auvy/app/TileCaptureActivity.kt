package com.auvy.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * Invisible activity that starts the microphone capture on the tile's behalf.
 *
 * RECORD_AUDIO is a "while-in-use" permission: the app must also be in a
 * state Android considers eligible to use it. A quick-settings tap runs the
 * TileService with the app in the background, so
 * `startForeground(…, MICROPHONE)` is refused even with the permission
 * granted.
 *
 * An Activity brings the app to the foreground, so the tile launches this: it
 * asks for RECORD_AUDIO if needed, starts the service, and finishes at once.
 * The running microphone foreground service then counts as eligible on its
 * own. Translucent, no history, no transition: it's never seen.
 */
class TileCaptureActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
                != android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                // Ask here — an Activity can, a TileService cannot. The next tap
                // will find the grant in place.
                requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), REQ)
                return
            }
            startCapture()
        } catch (e: Exception) {
            Log.w(TAG, "tile capture launch failed: ${e.javaClass.simpleName} ${e.message}")
        }
        finishQuietly()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ &&
            grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            // Granted just now, and we are still foreground — capture immediately
            // rather than making them tap the tile a second time.
            startCapture()
        }
        finishQuietly()
    }

    private fun startCapture() {
        startForegroundService(
            Intent(this, AudioCaptureService::class.java)
                .setAction(AudioCaptureService.ACTION_MIC)
                .putExtra(AudioCaptureService.EXTRA_SECONDS, 8.0),
        )
        Log.i(TAG, "mic capture started from foreground activity")
    }

    private fun finishQuietly() {
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        private const val TAG = "AuvyCapture"
        private const val REQ = 4719
    }
}
