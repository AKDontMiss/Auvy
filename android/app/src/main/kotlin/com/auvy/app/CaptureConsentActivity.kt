package com.auvy.app

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.util.Log

/**
 * Invisible activity whose only job is to ask for screen-audio consent and
 * immediately start a capture.
 *
 * WHY THIS EXISTS: THE TILE USED TO SEND YOU TO AUVY FIRST.
 *
 * Identifying music in another app took three steps — open Auvy, arm screen
 * audio, go back, then tap the tile. The arming had to happen in the app because
 * MediaProjection consent must come from a visible Activity; a TileService is not
 * one. So this IS that visible activity, reduced to nothing: no layout, a
 * transparent theme, no animation. It appears, the system dialog appears over it,
 * and it finishes.
 *
 * Result: tap tile → "Start now" → answer. The consent dialog itself cannot be
 * removed — Android requires a user-visible grant before any app may record what
 * is on screen, and that is a protection worth keeping. But it is now ONE dialog
 * in the flow rather than a detour through the app, and once armed, later taps
 * skip even that.
 */
class CaptureConsentActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Already armed (the tile normally checks, but a stale tile could send us
        // here anyway) — capture and get out without a redundant dialog.
        if (AudioCaptureService.isArmed) {
            startCapture()
            finishQuietly()
            return
        }
        try {
            val mgr = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(mgr.createScreenCaptureIntent(), REQ)
        } catch (e: Exception) {
            Log.w(TAG, "could not ask for screen capture: ${e.message}")
            finishQuietly()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ) {
            finishQuietly()
            return
        }
        if (resultCode != RESULT_OK || data == null) {
            Log.i(TAG, "screen-audio consent declined")
            finishQuietly()
            return
        }
        try {
            // ARM first so the projection is held for later taps, then capture
            // straight away — the user asked a question, not to configure a mode.
            startForegroundService(
                Intent(this, AudioCaptureService::class.java)
                    .setAction(AudioCaptureService.ACTION_ARM)
                    .putExtra(AudioCaptureService.EXTRA_RESULT_CODE, resultCode)
                    .putExtra(AudioCaptureService.EXTRA_RESULT_DATA, data),
            )
            startCapture()
        } catch (e: Exception) {
            Log.w(TAG, "arm+capture failed: ${e.message}")
        }
        finishQuietly()
    }

    private fun startCapture() {
        try {
            startForegroundService(
                Intent(this, AudioCaptureService::class.java)
                    .setAction(AudioCaptureService.ACTION_CAPTURE)
                    .putExtra(AudioCaptureService.EXTRA_SECONDS, 8.0),
            )
        } catch (e: Exception) {
            Log.w(TAG, "capture start failed: ${e.message}")
        }
    }

    /** No transition — this activity should never be seen arriving or leaving. */
    private fun finishQuietly() {
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    companion object {
        private const val TAG = "AuvyCapture"
        private const val REQ = 4717
    }
}
