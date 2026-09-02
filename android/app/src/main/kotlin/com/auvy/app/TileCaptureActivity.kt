package com.auvy.app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log

/**
 * Invisible activity that starts the microphone capture on the tile's behalf.
 *
 * WHY A TILE CANNOT START A MIC SERVICE DIRECTLY.
 *
 * RECORD_AUDIO is a "while-in-use" permission: holding the grant is not enough,
 * the app must also be in a state Android considers eligible to USE it. A
 * quick-settings tap runs the TileService while the app is in the BACKGROUND, so
 * `startForeground(…, MICROPHONE)` is refused even with RECORD_AUDIO granted and
 * FOREGROUND_SERVICE_MICROPHONE declared. The exception says so in as many words:
 *
 *   Starting FGS with type microphone … requires … anyOf [… RECORD_AUDIO]
 *   and the app must be in the eligible state/exemptions to access the
 *   foreground only permission
 *
 * That produced the "Could not listen — Android refused the microphone" notice
 * AFTER the permission had been granted, which looked like the grant not taking.
 *
 * An Activity is what makes the app foreground. So the tile launches this, it
 * starts the service while the app is legitimately in front, and finishes
 * immediately. The service keeps the mic afterwards because a running
 * microphone-typed foreground service is itself an eligible state.
 *
 * Translucent, no history, no transition — it must never be seen. This replaces
 * CaptureConsentActivity, which existed to host a MediaProjection dialog the mic
 * route does not need at all.
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
