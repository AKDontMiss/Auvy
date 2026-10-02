package com.auvy.app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import java.io.File

/**
 * Plays the wake-up alarm natively, with no Activity and no Flutter.
 *
 * An alarm has to make noise even if the phone is unlocked on the table and
 * nobody taps anything, so playback lives here:
 *
 * • A mediaPlayback foreground service started straight from the alarm
 *   broadcast. Receiving your own exact alarm (setAlarmClock) is one of the
 *   allowed exemptions for starting a foreground service from the background.
 * • It plays a LOCAL file downloaded ahead of time (see
 *   AlarmService.prepareTrack in Dart), so it needs no network.
 * • USAGE_ALARM, so it uses the alarm stream and Do Not Disturb lets it
 *   through like a clock app.
 * • If the file is missing it falls back to the system alarm ringtone.
 *
 * When the app comes to the foreground, Dart calls `alarmAudioState`, learns
 * what is playing and where, stops this service and continues the same
 * track through the normal player, so there is only ever one audio owner.
 */
class AlarmAudioService : Service() {

    private var player: MediaPlayer? = null
    private var focusRequest: AudioFocusRequest? = null
    private val handler = Handler(Looper.getMainLooper())
    private var fadeStartedAt = 0L
    private var targetVolume = 1.0f
    private var fadeFrom = START_VOLUME
    private var snoozeMinutes = SNOOZE_MINUTES_DEFAULT
    private var fadeMs = FADE_MS_DEFAULT
    private var usingFallback = false
    private var playingId: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "stop requested from notification")
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SNOOZE -> {
                snooze()
                stopSelf()
                return START_NOT_STICKY
            }
        }

        // A second alarm firing while this one rings must not stack a second
        // MediaPlayer on the same stream.
        if (isRinging) {
            Log.i(TAG, "already ringing — ignoring duplicate start")
            return START_NOT_STICKY
        }

        // Call startForeground first: there is only a few seconds' window after
        // startForegroundService, and missing it crashes the app. Everything that
        // can fail (file checks, audio focus, MediaPlayer.prepare) comes after.
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val title = prefs.getString("flutter.$PREF_TITLE", null) ?: "Wake up"
        val artist = prefs.getString("flutter.$PREF_ARTIST", null) ?: "Auvy alarm"
        startForeground(NOTIF_ID, buildNotification(title, artist))

        // The alarm is ringing, so any snooze has been consumed — drop its banner
        // and its recorded time, or the app would keep offering to cancel a snooze
        // that already happened.
        try {
            prefs.edit().remove("flutter.$PREF_SNOOZE_AT").apply()
            clearSnoozeNotice(this)
        } catch (_: Exception) {}

        instance = this
        isRinging = true

        val path = prefs.getString("flutter.$PREF_PATH", null)
        playingId = prefs.getString("flutter.$PREF_ID", null)
        val fadeIn = prefs.getBoolean("flutter.$PREF_FADE", true)
        // The user's alarm loudness, beneath the system ALARM stream volume.
        // An INT PERCENT, because a Dart int lands here as a Java Long — the same
        // encoding AlarmReceiver already relies on for the hour. Floored so a
        // slider at the bottom cannot produce a silent alarm.
        targetVolume =
            (prefs.getLong("flutter.$PREF_VOLUME_PCT", 100L).toFloat() / 100f)
                .coerceIn(0.05f, 1.0f)
        // Both user-adjustable. Read here rather than baked in as constants, and
        // clamped, so a bad stored value cannot produce a fade longer than the
        // alarm runs or a snooze of zero.
        snoozeMinutes = prefs
            .getLong("flutter.$PREF_SNOOZE_MIN", SNOOZE_MINUTES_DEFAULT.toLong()).toInt()
            .coerceIn(1, 60)
        fadeMs = prefs.getLong("flutter.$PREF_FADE_SEC", 30L) * 1000L
        fadeMs = fadeMs.coerceIn(0L, MAX_RUN_MS / 2)
        startPlayback(path, fadeIn)

        // Never ring forever: a phone left behind would play until the battery
        // died. Fifteen minutes is well past "the user is awake or has left".
        handler.postDelayed({ stopSelf() }, MAX_RUN_MS)
        // NOT_STICKY: a sticky service is re-created with a null intent after it
        // stops, which would fall through to "ring" and re-post the alarm
        // notification (or even start playing again). An alarm is one-shot; the
        // next one is AlarmManager's job.
        return START_NOT_STICKY
    }

    private fun startPlayback(path: String?, fadeIn: Boolean) {
        val file = path?.let { File(it) }
        val source: Uri? = if (file != null && file.exists() && file.length() > 0) {
            Uri.fromFile(file)
        } else {
            usingFallback = true
            playingId = null
            Log.w(TAG, "no pre-cached alarm track (path=$path) — falling back to the system alarm tone")
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        }
        if (source == null) {
            Log.w(TAG, "no playable alarm source at all — stopping")
            stopSelf()
            return
        }

        val attrs = AudioAttributes.Builder()
            // USAGE_ALARM is what makes Do Not Disturb let this through and
            // what puts it on the alarm volume rather than the media volume.
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        requestFocus(attrs)

        try {
            val mp = MediaPlayer()
            player = mp
            mp.setAudioAttributes(attrs)
            // Keeps the CPU alive across a screen-off Doze window. Cheaper and
            // better scoped than holding a WakeLock by hand, and it is released
            // with the player.
            mp.setWakeMode(applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
            mp.setDataSource(applicationContext, source)
            // One song is ~3 minutes; a sleeping user needs more than that.
            mp.isLooping = true
            mp.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "MediaPlayer error what=$what extra=$extra")
                // A corrupt cached file must still wake the user.
                if (!usingFallback) {
                    releasePlayer()
                    startPlayback(null, fadeIn)
                } else {
                    stopSelf()
                }
                true
            }
            mp.setOnPreparedListener {
                if (fadeIn) {
                    // Below the target, never above it: with the alarm volume set
                    // low, a fixed 0.06 start could be LOUDER than the target and
                    // the "fade in" would audibly fade DOWN.
                    fadeFrom = minOf(START_VOLUME, targetVolume * 0.25f)
                    it.setVolume(fadeFrom, fadeFrom)
                    fadeStartedAt = android.os.SystemClock.elapsedRealtime()
                    handler.post(fadeTick)
                } else {
                    it.setVolume(targetVolume, targetVolume)
                }
                it.start()
                Log.i(TAG, "alarm ringing (fallback=$usingFallback fade=$fadeIn)")
            }
            mp.prepareAsync()
        } catch (e: Exception) {
            Log.w(TAG, "alarm playback failed: ${e.javaClass.simpleName} ${e.message}")
            if (!usingFallback) {
                releasePlayer()
                startPlayback(null, fadeIn)
            } else {
                stopSelf()
            }
        }
    }

    /**
     * Ramp up over [FADE_MS] instead of starting at full blast — the whole point
     * of waking to music. Equal-power on a Stopwatch-style clock rather than a
     * step count, so a busy main thread makes the ramp coarser, never longer.
     */
    private val fadeTick = object : Runnable {
        override fun run() {
            val mp = player ?: return
            val elapsed = android.os.SystemClock.elapsedRealtime() - fadeStartedAt
            val t = (elapsed.toFloat() / fadeMs).coerceIn(0f, 1f)
            // sin(t·π/2): perceptually even, unlike a straight line which sounds
            // like it jumps at the start and crawls at the end.
            val v = fadeFrom + (targetVolume - fadeFrom) *
                kotlin.math.sin(t * Math.PI.toFloat() / 2f)
            try { mp.setVolume(v, v) } catch (_: IllegalStateException) { return }
            if (t < 1f) handler.postDelayed(this, 250L)
        }
    }

    private fun requestFocus(attrs: AudioAttributes) {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attrs)
                    // An alarm must not duck to a whisper behind something else.
                    .setWillPauseWhenDucked(false)
                    .build()
                focusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    null, AudioManager.STREAM_ALARM,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "audio focus request failed: ${e.message}")
        }
    }

    private fun abandonFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (_: Exception) {
        }
        focusRequest = null
    }

    /** Re-arm this same alarm [snoozeMinutes] from now, as a one-shot. */
    private fun snooze() {
        try {
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val at = System.currentTimeMillis() + snoozeMinutes * 60_000L
            val pi = snoozePendingIntent(this, create = true)!!
            am.setAlarmClock(AlarmManager.AlarmClockInfo(at, pi), pi)
            // Record the snooze time: AlarmManager can't be asked what is pending, so
            // without this the app wouldn't know a snooze is coming and couldn't offer
            // to cancel it. Stored as a Long because that's how a Dart int arrives here.
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit().putLong("flutter.$PREF_SNOOZE_AT", at).apply()
            postSnoozeNotice(this, at)
            Log.i(TAG, "snoozed $snoozeMinutes min (until $at)")
        } catch (e: Exception) {
            Log.w(TAG, "snooze failed: ${e.message}")
        }
    }

    private fun buildNotification(title: String, artist: String): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Wake-up alarm",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Plays your music when the wake-up alarm goes off"
                    setBypassDnd(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setSound(null, null) // the service IS the sound
                },
            )
        }

        val open = PendingIntent.getActivity(
            this, 8899,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(AlarmScheduler.EXTRA_ALARM, true)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        fun action(act: String, code: Int) = PendingIntent.getService(
            this, code, Intent(this, AlarmAudioService::class.java).setAction(act),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return androidx.core.app.NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(title)
            .setContentText(artist)
            .setPriority(androidx.core.app.NotificationCompat.PRIORITY_MAX)
            .setCategory(androidx.core.app.NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setContentIntent(open)
            // Still offered so a locked phone can show the app over the
            // lockscreen, but the music no longer depends on it being honoured.
            .setFullScreenIntent(open, true)
            .addAction(android.R.drawable.ic_media_pause, "Stop", action(ACTION_STOP, 8902))
            .addAction(android.R.drawable.ic_lock_idle_alarm, "Snooze", action(ACTION_SNOOZE, 8903))
            .build()
    }

    private fun releasePlayer() {
        handler.removeCallbacks(fadeTick)
        try { player?.stop() } catch (_: Exception) {}
        try { player?.release() } catch (_: Exception) {}
        player = null
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        // Take the notification with us. stopSelf() ends the service, but its
        // foreground notification can outlive it by a beat, which is the other
        // half of the "Auvy is still showing in the panel" residue. Belt and
        // braces: detach it, then cancel it by id in case the detach was a no-op.
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {}
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .cancel(NOTIF_ID)
        } catch (_: Exception) {}
        releasePlayer()
        abandonFocus()
        isRinging = false
        // Tell Dart the alarm is over, whatever ended it (the 15-minute cap, the
        // notification's Stop action, or the system stopping the service), so the
        // full-screen alarm screen closes instead of staying up on a silent phone.
        try { onStoppedListener?.invoke() } catch (_: Exception) {}
        // Static back-reference — clearing it is not optional, or the Service
        // (and its Context) outlives the process's need for it.
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "AuvyAlarm"
        private const val CHANNEL_ID = "auvy_alarm_playing"
        private const val NOTIF_ID = 8901

        private const val SNOOZE_CHANNEL_ID = "auvy_alarm_snoozed"
        private const val SNOOZE_NOTIF_ID = 8905

        const val ACTION_STOP = "com.auvy.app.ALARM_AUDIO_STOP"
        const val ACTION_SNOOZE = "com.auvy.app.ALARM_AUDIO_SNOOZE"
        /** Handled by [AlarmReceiver] — a broadcast, so it works with no service. */
        const val ACTION_CANCEL_SNOOZE = "com.auvy.app.CANCEL_SNOOZE"

        /// 10, not 9. Nine minutes is the mechanical clock-radio convention (it fits
        /// a single-digit counter), and copying it here only made people ask why
        /// their snooze was a minute short of the round number the button implies.
        private const val SNOOZE_MINUTES_DEFAULT = 10
        /** Request-code slot for the snooze one-shot; 0..7 are the real days. */
        private const val SNOOZE_SLOT = 8

        /// The PendingIntent the snooze one-shot is armed with.
        ///
        /// Built the same way every time so cancel() can find it: Android matches
        /// PendingIntents on action/data/type/component and request code, not extras.
        ///
        /// With [create] false it uses FLAG_NO_CREATE and returns null when no snooze
        /// is armed, which is how to ask "is a snooze pending?".
        private fun snoozePendingIntent(context: Context, create: Boolean): PendingIntent? {
            val intent = Intent(context, AlarmReceiver::class.java).apply {
                action = "com.auvy.app.ALARM"
                putExtra("weekday", SNOOZE_SLOT)
            }
            val flags = PendingIntent.FLAG_IMMUTABLE or
                if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE
            return PendingIntent.getBroadcast(context, 8800 + SNOOZE_SLOT, intent, flags)
        }

        /**
         * Epoch-ms a snooze will fire at, or 0 when none is pending.
         *
         * Cross-checks the recorded time against the live PendingIntent so a
         * leftover pref (the alarm was cancelled elsewhere, the user cleared it,
         * the phone rebooted and dropped every alarm) can never claim a snooze that
         * is not actually armed — and clears the stale value while it is here.
         */
        fun snoozeAt(context: Context): Long {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            val at = try { prefs.getLong("flutter.$PREF_SNOOZE_AT", 0L) } catch (_: Exception) { 0L }
            if (at <= System.currentTimeMillis()) {
                if (at != 0L) prefs.edit().remove("flutter.$PREF_SNOOZE_AT").apply()
                return 0L
            }
            if (snoozePendingIntent(context, create = false) == null) {
                prefs.edit().remove("flutter.$PREF_SNOOZE_AT").apply()
                return 0L
            }
            return at
        }

        /**
         * "Alarm snoozed · rings at 07:10" with a Cancel button, shown while a
         * snooze is pending, so it can be cancelled from the same place it was
         * tapped.
         *
         * Uses its own low-importance channel: no sound, vibration or heads-up.
         */
        private fun postSnoozeNotice(context: Context, at: Long) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            SNOOZE_CHANNEL_ID, "Snoozed alarm",
                            NotificationManager.IMPORTANCE_LOW,
                        ).apply {
                            description = "Shows a snoozed alarm, so it can be cancelled"
                            setSound(null, null)
                            enableVibration(false)
                        },
                    )
                }
                val c = java.util.Calendar.getInstance().apply { timeInMillis = at }
                val hh = c.get(java.util.Calendar.HOUR_OF_DAY).toString().padStart(2, '0')
                val mm = c.get(java.util.Calendar.MINUTE).toString().padStart(2, '0')

                // A BROADCAST, NOT startService. Android 12+ refuses a background
                // service start, and by the time this button is tapped the alarm
                // service is long gone, so routing Cancel through the service (as
                // Stop and Snooze do, while it is running in the foreground) would
                // throw BackgroundServiceStartNotAllowedException and do nothing.
                val cancel = PendingIntent.getBroadcast(
                    context, 8906,
                    Intent(context, AlarmReceiver::class.java).setAction(ACTION_CANCEL_SNOOZE),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                val open = PendingIntent.getActivity(
                    context, 8907,
                    Intent(context, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                nm.notify(
                    SNOOZE_NOTIF_ID,
                    androidx.core.app.NotificationCompat.Builder(context, SNOOZE_CHANNEL_ID)
                        .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                        .setContentTitle("Alarm snoozed")
                        .setContentText("Rings again at $hh:$mm")
                        .setPriority(androidx.core.app.NotificationCompat.PRIORITY_LOW)
                        .setCategory(androidx.core.app.NotificationCompat.CATEGORY_ALARM)
                        .setOngoing(true)
                        .setShowWhen(false)
                        .setSilent(true)
                        .setContentIntent(open)
                        .addAction(android.R.drawable.ic_menu_close_clear_cancel,
                            "Cancel snooze", cancel)
                        .build(),
                )
            } catch (e: Exception) {
                Log.w(TAG, "snooze notice failed: ${e.message}")
            }
        }

        /** Take the snooze banner down — the snooze fired, or was called off. */
        fun clearSnoozeNotice(context: Context) {
            try {
                (context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager).cancel(SNOOZE_NOTIF_ID)
            } catch (_: Exception) {}
        }

        /** Call off a pending snooze. Returns true when there was one to cancel. */
        fun cancelSnooze(context: Context): Boolean {
            val pi = snoozePendingIntent(context, create = false)
            try {
                val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                if (pi != null) {
                    am.cancel(pi)
                    // cancel() the PendingIntent itself as well, so a later
                    // FLAG_NO_CREATE lookup genuinely reports "nothing armed".
                    pi.cancel()
                }
            } catch (e: Exception) {
                Log.w(TAG, "cancelSnooze failed: ${e.message}")
            }
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit().remove("flutter.$PREF_SNOOZE_AT").apply()
            clearSnoozeNotice(context)
            Log.i(TAG, "snooze cancelled (was armed: ${pi != null})")
            return pi != null
        }
        private const val MAX_RUN_MS = 15 * 60 * 1000L
        private const val FADE_MS_DEFAULT = 30_000L
        private const val START_VOLUME = 0.06f

        /** Pref keys, written by Dart's AlarmService.prepareTrack. */
        const val PREF_PATH = "auvy_alarm_track_path"
        const val PREF_ID = "auvy_alarm_track_id"
        const val PREF_TITLE = "auvy_alarm_track_title"
        const val PREF_ARTIST = "auvy_alarm_track_artist"
        const val PREF_FADE = "auvy_alarm_fade_in"
        const val PREF_SNOOZE_MIN = "auvy_alarm_snooze_min"
        /** Written HERE, not by Dart: the epoch-ms a pending snooze fires at. */
        const val PREF_SNOOZE_AT = "auvy_alarm_snooze_at"
        const val PREF_FADE_SEC = "auvy_alarm_fade_seconds"
        const val PREF_VOLUME_PCT = "auvy_alarm_volume_pct"

        @Volatile
        var isRinging = false
            private set

        @Volatile
        private var instance: AlarmAudioService? = null

        /// Invoked when the alarm stops for ANY reason. Set by MainActivity so the
        /// ringing screen can close itself; see the note in onDestroy.
        @Volatile
        var onStoppedListener: (() -> Unit)? = null

        /**
         * What is ringing and where it has got to, so Dart can continue the same
         * track at the same position instead of restarting it.
         */
        fun snapshot(): Map<String, Any?> {
            val svc = instance
            val pos = try { svc?.player?.currentPosition?.toLong() ?: 0L } catch (_: Exception) { 0L }
            return mapOf(
                "active" to isRinging,
                "videoId" to svc?.playingId,
                "positionMs" to pos,
                "fallback" to (svc?.usingFallback ?: false),
            )
        }

        fun start(context: Context) {
            val intent = Intent(context, AlarmAudioService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Never let a failed start take the receiver down with it — the
                // full-screen notification is still posted either way.
                Log.w(TAG, "could not start alarm audio service: ${e.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, AlarmAudioService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
