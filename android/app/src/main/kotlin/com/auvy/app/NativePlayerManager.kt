package com.auvy.app

import android.content.Context
import android.net.Uri
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Metadata
import androidx.media3.extractor.metadata.icy.IcyInfo
import androidx.media3.extractor.metadata.icy.IcyHeaders
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.ContentMetadataMutations
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class NativePlayerManager(context: Context, private val channel: MethodChannel) {
    private val appContext = context.applicationContext

    companion object {
        // The single, process-wide ExoPlayer. Created once and reused across every
        // FlutterEngine / Activity recreation (rotation, returning from background,
        // theme change), so there are never two players alive playing over each
        // other.
        @Volatile private var sharedPlayer: ExoPlayer? = null

        /// The output the user pinned Auvy to, or -1 for "follow the system".
        /// Lives with the shared player because that is what it applies to.
        /// Deliberately NOT persisted across launches: a pin to a device that is
        /// no longer attached would leave the player aimed at nothing, and going
        /// silent after a restart is worse than re-picking.
        @Volatile private var sharedPreferredOutputId: Int = -1
        // The 2Hz position feed. Held as a field so it can be re-posted on demand
        // and, crucially, STOPPED. See startPositionTicks and the tick body.
        @Volatile private var positionTick: Runnable? = null
        @Volatile private var positionTicking: Boolean = false
        // Always points at the MOST RECENT channel, so the single listener /
        // position reporter report to the live engine after a recreation.
        @Volatile private var activeChannel: MethodChannel? = null

        /// Put a short diagnostic in the log Dart can export.
        ///
        /// android.util.Log only reaches logcat, while the log users export is built
        /// from Dart's print zone, so important native events (audio focus changes,
        /// fatal stream refusals, network outages) are forwarded here.
        ///
        /// For rare, decisive events only: this crosses the platform channel and
        /// wakes the Dart isolate, so nothing per-chunk or per-tick belongs here.
        /// Best-effort: if there's no channel, the note is dropped.
        ///
        /// Always hops to the main thread, because a MethodChannel may only be
        /// invoked there and most callers run on ExoPlayer's playback or loader
        /// threads.
        internal fun noteToDart(msg: String) {
            mainHandler.post {
                try {
                    activeChannel?.invokeMethod("onNativeNote", mapOf("msg" to msg))
                } catch (_: Exception) {
                }
            }
        }
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        // "Pause when muted" watcher.
        // Android doesn't pause playback when the volume hits zero, so this watches
        // the MEDIA stream and tells Dart when it reaches 0. The pause itself is done
        // in Dart so the player state, media session and notification stay in sync.
        // Installed once per process (`volumeWatcher != null` guard) so an activity
        // recreation doesn't add a duplicate observer.
        @Volatile private var volumeWatcher: android.database.ContentObserver? = null
        @Volatile private var lastVolume: Int = -1

        private fun installVolumeWatcher(context: Context) {
            if (volumeWatcher != null) return
            val am = context.getSystemService(Context.AUDIO_SERVICE)
                as android.media.AudioManager
            lastVolume = try {
                am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
            } catch (_: Exception) { -1 }

            val observer = object : android.database.ContentObserver(mainHandler) {
                override fun onChange(selfChange: Boolean) {
                    val vol = try {
                        am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                    } catch (_: Exception) { return }
                    val previous = lastVolume
                    lastVolume = vol
                    // Only the TRANSITION to zero counts. Firing on every change
                    // (or while already at zero) would pause repeatedly and fight
                    // a user who is deliberately turning it back up.
                    if (vol == 0 && previous != 0) {
                        activeChannel?.invokeMethod("onVolumeMuted", null)
                    }
                }
            }
            try {
                context.contentResolver.registerContentObserver(
                    android.provider.Settings.System.CONTENT_URI, true, observer)
                volumeWatcher = observer
            } catch (e: Exception) {
                android.util.Log.w("AuvyPlayer", "volume watcher failed: ${e.message}")
            }
        }

        // Track-transition wake locks.
        // The queue advance runs in Dart: ENDED → method channel → resolve the next
        // stream URL → play. With the screen off, ExoPlayer releases its own wake
        // lock at ENDED, and the device could suspend before Dart's advance ran.
        // These timed locks cover that gap; they're released as soon as the next
        // track reaches STATE_READY, or after 90s at most.
        @Volatile private var transitionWake: android.os.PowerManager.WakeLock? = null
        @Volatile private var transitionWifi: android.net.wifi.WifiManager.WifiLock? = null
        private val transitionRelease = Runnable { releaseTransitionLocks() }

        // App-managed audio focus.
        // ExoPlayer is built with handleAudioFocus=false and the app requests focus
        // itself, so it can decide per case: pause on a loss and resume on gain if
        // the loss was short (or a phone call) and nothing else is playing; duck on
        // CAN_DUCK. Call detection is best-effort via AudioManager.mode
        // (permission-free).
        @Volatile private var audioManager: android.media.AudioManager? = null
        @Volatile private var audioFocusRequest: android.media.AudioFocusRequest? = null
        // True once we hold focus; guards against re-requesting every play tick.
        @Volatile private var hasAudioFocus = false
        // We paused because of a TRANSIENT loss (nav prompt / notification) —
        // auto-resume when focus returns. A permanent loss (another music app,
        // a video app taking full focus) clears this: the user resumes manually.
        @Volatile private var resumeOnFocusGain = false
        // When that transient loss happened, and whether a call was in progress
        // at the time. Both exist because "transient" is a claim the system makes
        // and does not keep. See the GAIN branch.
        @Volatile private var transientLossAtMs = 0L
        @Volatile private var lostToCall = false
        /// How long a transient loss may last and still be treated as one. Nav
        /// prompts and notification sounds are over in seconds; anything longer
        /// (e.g. Instagram taking transient focus per reel) means the user has moved
        /// on to another app.
        private const val TRANSIENT_RESUME_WINDOW_MS = 60_000L
        // The volume Dart last asked for (fade-in ramp / user setting). Focus
        // ducking drops to 0.2 then restores to THIS, so we never fight Dart's
        // volume state.
        @Volatile private var appVolume = 1.0f

        // Adaptive bitrate: the measurements Dart decides from
        /// media3's throughput estimator. See where it is built for why we hold it.
        @Volatile private var bandwidthMeter:
            androidx.media3.exoplayer.upstream.DefaultBandwidthMeter? = null

        /// Mid-track buffer underruns since the counter was last read. Only stalls
        /// after playback is under way count; every track start buffers, and
        /// counting that would pin quality to the floor on a perfect connection.
        @Volatile private var stallCount = 0
        /// When the playhead last jumped for a seek, so its re-buffer is not a stall.
        @Volatile private var lastSeekAtMs = 0L

        private fun holdTransitionLocks(context: Context) {
            try {
                if (transitionWake == null) {
                    val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                    transitionWake = pm.newWakeLock(
                        android.os.PowerManager.PARTIAL_WAKE_LOCK, "auvy:trackTransition"
                    ).apply { setReferenceCounted(false) }
                }
                if (transitionWifi == null) {
                    val wm = context.applicationContext
                        .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                    @Suppress("DEPRECATION")
                    transitionWifi = wm.createWifiLock(
                        android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "auvy:trackTransition"
                    ).apply { setReferenceCounted(false) }
                }
                transitionWake?.acquire(90_000L)
                if (transitionWifi?.isHeld != true) transitionWifi?.acquire()
                // WifiLock has no timeout of its own — mirror the wake lock's.
                mainHandler.removeCallbacks(transitionRelease)
                mainHandler.postDelayed(transitionRelease, 90_000L)
            } catch (e: Exception) {
                android.util.Log.e("AuvyPlayer", "transition lock acquire failed: ${e.message}")
            }
        }

        private fun releaseTransitionLocks() {
            try { mainHandler.removeCallbacks(transitionRelease) } catch (_: Exception) {}
            try { if (transitionWake?.isHeld == true) transitionWake?.release() } catch (_: Exception) {}
            try { if (transitionWifi?.isHeld == true) transitionWifi?.release() } catch (_: Exception) {}
        }

        // Fallback UA (matches the ANDROID stream client) if Dart doesn't supply one.
        private const val DEFAULT_UA =
            "com.google.android.youtube/20.10.38 (Linux; U; Android 14; en_US; Pixel 8 Pro Build/UD1A.231105.004) gzip"

        // Live streaming resilience.
        // The player is never handed a fixed URL. A ResolvingDataSource resolves the
        // stream URL lazily, per byte range, from this expiry-keyed cache, and asks
        // Dart to re-resolve when it expires, 403s or the network changes. A media3
        // SimpleCache underneath stores bytes as they stream, so replays and
        // re-buffers read from disk.
        private const val CHUNK_LENGTH = 512L * 1024

        /// videoId → contentLength of the format currently BEING PLAYED.
        ///
        /// SEPARATE FROM songUrlCache ON PURPOSE. The 403 path REMOVES the url
        /// cache entry before re-resolving, which is exactly when this value is
        /// needed — it is what tells Dart which format to hand back. Cleared only
        /// when a track actually starts, never by a failure.
        @JvmStatic
        val inUseContentLength = java.util.concurrent.ConcurrentHashMap<String, Long>()

        data class UrlEntry(
            val url: String,
            val userAgent: String,
            val contentLength: Long,
            val expiresAtMs: Long,
        )

        // videoId → resolved stream URL (+ expiry). Shared process-wide.
        @JvmStatic
        val songUrlCache = ConcurrentHashMap<String, UrlEntry>()

        /// Caps for the two static maps, so they can't grow for the life of the
        /// process (a URL plus user-agent is ~1.5 KB per track). Only the playing and
        /// upcoming tracks are ever read, so these limits are generous; they just
        /// make the ceiling finite. See pruneCaches for why the two differ.
        private const val MAX_URL_CACHE = 96
        private const val MAX_PIN_CACHE = 512

        /// Play-cache metadata key holding the contentLength of the format whose
        /// bytes are stored under a videoId. See reconcileCacheFormat. Named so it
        /// cannot collide with media3's own keys.
        private const val META_FORMAT_CLEN = "auvy_format_clen"

        // Pre-warm the next track's first bytes into the play-cache while the
        // current track plays, so the transition starts INSTANTLY from cache
        // (kills the ~2s resolve+buffer gap) — only ~1 MB, so a queue edit wastes
        // almost nothing (vs a whole-track pre-download).
        private const val PREWARM_BYTES = 1L * 1024 * 1024

        /// How many 403 retries reuse the SAME cached URL before escalating to a
        /// re-resolve. A URL with hours of validity left is not the reason a
        /// mid-file range was refused, and handing each retry a brand-new URL is
        /// actively worse. See the 403 branch in `resilientPolicy`.
        private const val SAME_URL_403_RETRIES = 4

        /// How many FRESH-url attempts a 403 gets before handing over to Dart.
        ///
        /// Kept small on purpose: each one is a full resolve, and if three
        /// different URLs are all refused then the URL is not the problem. See the
        /// give-up branch in getRetryDelayMsFor for the arithmetic.
        private const val MAX_403_ESCALATIONS = 3
        @Volatile private var prewarmThread: Thread? = null

        // The videoId of the range currently being loaded, so the load-error
        // policy can drop the RIGHT cache entry on a 403 (forces a fresh resolve
        // on the retry). Single active track load at a time, so a field suffices.
        @Volatile private var currentResolveKey: String? = null

        // media3 streaming play-cache (LRU). Singleton per process (SimpleCache
        // refuses a second instance on the same dir). Only caches bytes actually
        // streamed — NOT speculative pre-download.
        @Volatile private var playerCache: SimpleCache? = null
        private const val PLAYER_CACHE_BYTES = 512L * 1024 * 1024  // 512 MB LRU

        private fun getPlayerCache(context: Context): SimpleCache {
            playerCache?.let { return it }
            synchronized(this) {
                playerCache?.let { return it }
                // The stream cache lives in cacheDir, not filesDir: it's a re-downloadable
                // LRU buffer, so Android should report it as Cache, "Clear cache" should
                // clear it, and the system may reclaim it under storage pressure. (The Dart
                // audio cache of tracks the user chose to keep stays in app data.) The old
                // filesDir copy is deleted below; the moved cache simply starts cold.
                val legacy = File(context.filesDir, "auvy_stream_cache")
                if (legacy.exists()) {
                    try { legacy.deleteRecursively() } catch (_: Exception) {}
                }
                val dir = File(context.cacheDir, "auvy_stream_cache")
                val evictor = LeastRecentlyUsedCacheEvictor(PLAYER_CACHE_BYTES)
                val db = StandaloneDatabaseProvider(context.applicationContext)
                val cache = SimpleCache(dir, evictor, db)
                playerCache = cache
                return cache
            }
        }

        /// Compute the URL's own expiry from its `expire=<epoch seconds>` param
        /// (googlevideo). Falls back to +5 min when absent so we still re-resolve.
        private fun expiryFromUrl(url: String): Long {
            return try {
                val exp = Uri.parse(url).getQueryParameter("expire")?.toLongOrNull()
                if (exp != null) exp * 1000L else System.currentTimeMillis() + 5 * 60_000L
            } catch (_: Exception) {
                System.currentTimeMillis() + 5 * 60_000L
            }
        }

        // DSP effect state (shared, survives NativePlayerManager recreation)
        // The system Equalizer attaches to the ExoPlayer AUDIO SESSION; it's
        // rebuilt whenever the session changes (onAudioSessionIdChanged) and on
        // every toggle, re-applying the saved state. Pitch/speed go straight into
        // PlaybackParameters (kept in sync so setting one preserves the other).
        @Volatile private var equalizer: Equalizer? = null
        @Volatile private var eqEnabled = false
        private val eqBandsDb = FloatArray(5)  // dB per UI band
        // UI band centres in milliHz: 60 / 230 / 910 / 3600 / 14000 Hz.
        private val uiFreqsMilliHz = intArrayOf(60_000, 230_000, 910_000, 3_600_000, 14_000_000)
        @Volatile private var currentPitch = 1.0f
        @Volatile private var currentSpeed = 1.0f

        // Volume normalization (LoudnessEnhancer)
        // Gain is expressed in MILLIBELS, computed in Dart from YouTube's own
        // audioConfig.loudnessDb for the track (see AudioService.resolveStream).
        // ±20 dB is plenty for real-world masters and
        // keeps a bad/absent loudness value from blowing the mix apart.
        const val MIN_GAIN_MB = -2000
        const val MAX_GAIN_MB = 2000
        @Volatile private var loudnessEnhancer: LoudnessEnhancer? = null
        @Volatile private var normalizationEnabled = false
        @Volatile private var normalizationGainMb = 0

        /// (Re)attach the LoudnessEnhancer to [sessionId] and push the saved gain.
        /// Called on session change and whenever Dart sends a new gain. LoudnessEnhancer
        /// only supports POSITIVE targetGain, so attenuation (a loud master) is applied
        /// as a player-volume trim instead — together they cover both directions.
        private fun applyNormalization(sessionId: Int) {
            try { loudnessEnhancer?.release() } catch (_: Exception) {}
            loudnessEnhancer = null
            if (sessionId == C.AUDIO_SESSION_ID_UNSET || sessionId == 0) return
            if (!normalizationEnabled || normalizationGainMb == 0) return
            try {
                if (normalizationGainMb > 0) {
                    val le = LoudnessEnhancer(sessionId)
                    le.setTargetGain(normalizationGainMb)
                    le.enabled = true
                    loudnessEnhancer = le
                }
                android.util.Log.i("AuvyPlayer",
                    "normalization gain=${normalizationGainMb}mB (session=$sessionId)")
            } catch (e: Exception) {
                android.util.Log.e("AuvyPlayer", "LoudnessEnhancer init failed: ${e.message}")
                // Volume normalisation is now silently off. The setting still
                // reads as on, so without this the only symptom is that it
                // does nothing.
                noteToDart("volume normalisation unavailable on this device (${e.message})")
            }
        }

        /// The attenuation half of normalization: a NEGATIVE gain can't go through
        /// LoudnessEnhancer, so fold it into the player volume. Returns the scale to
        /// multiply the user's volume by (1.0 when boosting or disabled).
        fun normalizationVolumeScale(): Float {
            if (!normalizationEnabled || normalizationGainMb >= 0) return 1.0f
            return Math.pow(10.0, normalizationGainMb / 2000.0).toFloat().coerceIn(0.1f, 1.0f)
        }

        /// (Re)attach the Equalizer to [sessionId] and push the saved bands/enabled
        /// state. Called on session change + on toggle. No-op for an unset session.
        private fun rebuildEqualizer(sessionId: Int) {
            try { equalizer?.release() } catch (_: Exception) {}
            equalizer = null
            if (sessionId == C.AUDIO_SESSION_ID_UNSET || sessionId == 0) return
            try {
                val eq = Equalizer(0, sessionId)
                applyBandsTo(eq)
                eq.enabled = eqEnabled
                equalizer = eq
            } catch (e: Exception) {
                android.util.Log.e("AuvyPlayer", "Equalizer init failed: ${e.message}")
                // Same shape as above: the EQ screen keeps its sliders and
                // changes nothing, with no trace in an export to say why.
                noteToDart("equalizer unavailable on this device (${e.message})")
            }
        }

        /// Map the 5 UI bands (dB) onto the hardware EQ's bands by nearest centre
        /// frequency, clamped to the device's supported level range.
        private fun applyBandsTo(eq: Equalizer) {
            try {
                val n = eq.numberOfBands.toInt()
                if (n <= 0) return
                val range = eq.bandLevelRange          // millibels [min, max]
                val minL = range[0].toInt(); val maxL = range[1].toInt()
                for (i in uiFreqsMilliHz.indices) {
                    val targetMb = (eqBandsDb[i] * 100f).toInt().coerceIn(minL, maxL)
                    var best = 0; var bestDiff = Long.MAX_VALUE
                    for (b in 0 until n) {
                        val center = eq.getCenterFreq(b.toShort()).toLong()
                        val diff = kotlin.math.abs(center - uiFreqsMilliHz[i].toLong())
                        if (diff < bestDiff) { bestDiff = diff; best = b }
                    }
                    eq.setBandLevel(best.toShort(), targetMb.toShort())
                }
            } catch (e: Exception) {
                android.util.Log.e("AuvyPlayer", "Equalizer apply failed: ${e.message}")
            }
        }
    }

    // Non-null handle to the shared player for this instance's helpers.
    private val player: ExoPlayer

    /// Mirrors [sharedPreferredOutputId]. `ExoPlayer.preferredAudioDevice` has no
    /// getter, so this is the only record of the chosen output. Stored at process
    /// level (like the player itself) so a new manager after an engine reattach
    /// still knows it.
    private var preferredOutputId: Int
        get() = sharedPreferredOutputId
        set(value) { sharedPreferredOutputId = value }

    private var outputDetachWatcher: android.media.AudioDeviceCallback? = null

    /// Drops the pin the moment the pinned device detaches, so audio falls back
    /// to the system route instead of being aimed at something that is gone.
    ///
    /// Unplugging headphones mid-track would otherwise leave the player pointed
    /// at a dead sink — silence with no visible cause and no way to recover
    /// except re-picking a device.
    private fun releasePinOnDetach(watch: Boolean) {
        try {
            val am = appContext.getSystemService(Context.AUDIO_SERVICE)
                as? android.media.AudioManager ?: return
            outputDetachWatcher?.let { am.unregisterAudioDeviceCallback(it) }
            outputDetachWatcher = null
            if (!watch) return
            val cb = object : android.media.AudioDeviceCallback() {
                override fun onAudioDevicesRemoved(
                    removed: Array<out android.media.AudioDeviceInfo>?
                ) {
                    val pinned = preferredOutputId
                    if (pinned < 0) return
                    if (removed?.any { it.id == pinned } == true) {
                        preferredOutputId = -1
                        try {
                            player.setPreferredAudioDevice(null)
                        } catch (_: Exception) {}
                        android.util.Log.i("AuvyPlayer",
                            "Pinned output detached — following the system again")
                    }
                }
            }
            am.registerAudioDeviceCallback(cb, android.os.Handler(android.os.Looper.getMainLooper()))
            outputDetachWatcher = cb
        } catch (_: Exception) {
        }
    }

    init {
        // Latest channel always wins (callbacks below route to it).
        activeChannel = channel
        installVolumeWatcher(appContext)

        val existing = sharedPlayer
        if (existing == null) {
            // First creation — build the one player and install its listener +
            // position reporter EXACTLY ONCE.
            val loadControl = DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                    /* minBufferMs = */ 25_000,
                    /* maxBufferMs = */ 60_000,
                    /* bufferForPlaybackMs = */ 2_500,
                    /* bufferForPlaybackAfterRebufferMs = */ 4_000
                )
                .setPrioritizeTimeOverSizeThresholds(true)
                .setBackBuffer(10_000, false)
                .build()
            // Audio attributes: USAGE_MEDIA keeps this on the MEDIA stream, fully
            // separate from the call's voice uplink — the person on the other end
            // of a phone call can NEVER hear this (they only hear the mic; the one
            // exception is acoustic bleed on speakerphone). Never use
            // USAGE_VOICE_COMMUNICATION here or it WOULD route into the call.
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
                .build()
            // handleAudioFocus=false: focus is requested and handled by the app (see
            // the audio focus listener), not by ExoPlayer. setHandleAudioBecomingNoisy
            // still pauses when headphones or Bluetooth disconnect.
            // WAKE_MODE_NETWORK: hold a partial wake lock and Wi-Fi lock while playing
            // remote streams, so the buffer keeps refilling with the screen off.
            // An explicit bandwidth meter, so Dart can read the measured throughput when
            // choosing a quality at resolve time (a much better signal than "Wi-Fi or
            // mobile?"). One per process, so the estimate isn't re-learned per player.
            val meter = androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
                .Builder(appContext)
                .build()
            bandwidthMeter = meter
            val p = ExoPlayer.Builder(appContext)
                .setLoadControl(loadControl)
                .setBandwidthMeter(meter)
                .setAudioAttributes(audioAttributes, /* handleAudioFocus= */ false)
                .setHandleAudioBecomingNoisy(true)
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .build()
            sharedPlayer = p
            player = p
            installPlayerInfra(p)
        } else {
            player = existing
        }

        // (Re)bind the latest channel's method handler to the shared player.
        bindMethodHandler()
    }

    // Listener + position reporter — installed once on the single player; both
    // report to [activeChannel] so they follow the live engine after recreation.
    private fun installPlayerInfra(p: ExoPlayer) {
        // App-managed audio focus (see the companion-object block). Built once,
        // here, since this method runs exactly once per process.
        setupAudioFocus()
        p.addListener(object : Player.Listener {
            // Playback just started (or resumed) → grab audio focus so OTHER
            // media apps yield to us, and so we START getting focus-change
            // callbacks (which is how we pause when THEY take over).
            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                // Log why playWhenReady changed (audio focus, headphones unplugged, remote
                // control, or our own Dart code), so "it paused by itself" can be diagnosed.
                val why = when (reason) {
                    Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST -> "USER_REQUEST (someone called play/pause — including our own Dart)"
                    Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_FOCUS_LOSS -> "AUDIO_FOCUS_LOSS (another app took the output)"
                    Player.PLAY_WHEN_READY_CHANGE_REASON_AUDIO_BECOMING_NOISY -> "AUDIO_BECOMING_NOISY (output device went away)"
                    Player.PLAY_WHEN_READY_CHANGE_REASON_REMOTE -> "REMOTE (notification, watch, Auto, Assistant)"
                    Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM -> "END_OF_MEDIA_ITEM"
                    else -> "reason=$reason"
                }
                android.util.Log.i("AuvyPlayer", "playWhenReady=$playWhenReady — $why")
                // A pause the system made (output gone, remote) goes to the activity log
                // too; our own calls and track ends are already visible there.
                if (!playWhenReady &&
                    reason != Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST &&
                    reason != Player.PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM) {
                    noteToDart("paused by the system — $why")
                }
                if (playWhenReady) requestAudioFocusIfNeeded()
            }

            // Log playback suppression: media3 can silence audio while playWhenReady
            // stays true (only isPlaying flips), e.g. on a transient focus loss or a
            // momentarily invalid route during a Bluetooth codec switch. Without this it
            // looks identical to a network rebuffer.
            override fun onPlaybackSuppressionReasonChanged(reason: Int) {
                val why = when (reason) {
                    Player.PLAYBACK_SUPPRESSION_REASON_NONE -> "NONE (audio resumed)"
                    Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS -> "TRANSIENT_AUDIO_FOCUS_LOSS (something else briefly took the output)"
                    Player.PLAYBACK_SUPPRESSION_REASON_UNSUITABLE_AUDIO_ROUTE -> "UNSUITABLE_AUDIO_ROUTE"
                    else -> "reason=$reason"
                }
                android.util.Log.i(
                    "AuvyPlayer",
                    "playback SUPPRESSED/restored — $why (playWhenReady=${p.playWhenReady} isPlaying=${p.isPlaying})"
                )
            }

            // Live streams do not seek, so a discontinuity on one means
            // something reconnected or the window slid. Names which, so a
            // rebuffer stops being indistinguishable from a suppression.
            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int
            ) {
                val why = when (reason) {
                    Player.DISCONTINUITY_REASON_AUTO_TRANSITION -> "AUTO_TRANSITION"
                    Player.DISCONTINUITY_REASON_SEEK -> "SEEK"
                    Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT -> "SEEK_ADJUSTMENT"
                    Player.DISCONTINUITY_REASON_SKIP -> "SKIP"
                    Player.DISCONTINUITY_REASON_REMOVE -> "REMOVE"
                    Player.DISCONTINUITY_REASON_INTERNAL -> "INTERNAL (source reset — a live stream reconnecting looks like this)"
                    else -> "reason=$reason"
                }
                android.util.Log.i(
                    "AuvyPlayer",
                    "position discontinuity ${oldPosition.positionMs}ms -> ${newPosition.positionMs}ms — $why"
                )
                if (reason == Player.DISCONTINUITY_REASON_SEEK ||
                    reason == Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT) {
                    lastSeekAtMs = android.os.SystemClock.elapsedRealtime()
                }
                // The playhead just moved without playback moving it, which is
                // the one case the position feed cannot infer. While PLAYING
                // this is a no-op (the feed is already running); while PAUSED
                // it delivers exactly one update and stops again, so a scrub
                // with the track paused still reports where it actually landed.
                startPositionTicks()
            }
            override fun onPlayerError(error: PlaybackException) {
                android.util.Log.e("AuvyPlayer", "onPlayerError code=${error.errorCodeName} msg=${error.message} playWhenReady=${p.playWhenReady}")
                // Error recovery re-resolves over the network from Dart — keep
                // the CPU/WiFi up so the retry can actually run with screen off.
                holdTransitionLocks(appContext)
                activeChannel?.invokeMethod(
                    "onPlayerError",
                    mapOf(
                        "code" to error.errorCodeName,
                        "message" to (error.message ?: ""),
                        // The user's play/pause INTENT. ExoPlayer keeps playWhenReady
                        // across an error, but isPlaying went false the moment the
                        // buffer underran — often 10-30s BEFORE the error surfaces.
                        // Dart's self-heal must resume from this intent; deriving it
                        // from isPlaying reloaded the track paused ("stops mid-track").
                        "playWhenReady" to p.playWhenReady
                    )
                )
            }

            override fun onPlaybackStateChanged(state: Int) {
                val s = when (state) { 1 -> "IDLE"; 2 -> "BUFFERING"; 3 -> "READY"; 4 -> "ENDED"; else -> "?" }
                android.util.Log.i("AuvyPlayer", "state=$s")
                // Any move out of IDLE means there is a position to report again.
                // Idempotent, so this cannot stack duplicate tickers.
                if (state != Player.STATE_IDLE) startPositionTicks()
                // Forward mid-track stalls to Dart so the UI can say "reconnecting" rather
                // than showing a playing track with a frozen position (Dart decides whether
                // a stall lasts long enough to show). A stall is BUFFERING after the track is
                // under way while the user still wants it playing; track starts and seeks
                // also buffer and are excluded (see stallCount).
                val afterSeek =
                    android.os.SystemClock.elapsedRealtime() - lastSeekAtMs < 2_000L
                val midTrack = state == Player.STATE_BUFFERING &&
                    p.playWhenReady &&
                    p.currentPosition > 3_000L &&
                    !afterSeek
                if (midTrack) {
                    stallCount++
                    android.util.Log.i("AuvyPlayer",
                        "mid-track stall #$stallCount at ${p.currentPosition}ms " +
                            "(est ${bandwidthMeter?.bitrateEstimate ?: -1} bps)")
                }
                activeChannel?.invokeMethod(
                    "onBuffering",
                    mapOf(
                        "buffering" to (state == Player.STATE_BUFFERING),
                        "midTrack" to midTrack,
                    ))
                if (state == Player.STATE_ENDED) {
                    // Bridge the Dart-driven advance (see companion docs) BEFORE
                    // notifying, so the device can't suspend under the resolve.
                    holdTransitionLocks(appContext)
                    activeChannel?.invokeMethod("onTrackEnded", null)
                } else if (state == Player.STATE_READY) {
                    // Next track is loaded — ExoPlayer's own WAKE_MODE_NETWORK
                    // lock takes over from here.
                    releaseTransitionLocks()
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                android.util.Log.i("AuvyPlayer", "isPlaying=$isPlaying playWhenReady=${p.playWhenReady} state=${p.playbackState}")
                // Belt and braces: play/pause can arrive without a state change
                // (e.g. resuming an already-READY item).
                if (isPlaying) startPositionTicks()
                activeChannel?.invokeMethod("onIsPlayingChanged", mapOf(
                    "isPlaying" to isPlaying,
                    "playWhenReady" to p.playWhenReady
                ))
            }

            override fun onMediaMetadataChanged(mediaMetadata: MediaMetadata) {
                val title = mediaMetadata.title?.toString()?.trim()
                val artist = mediaMetadata.artist?.toString()?.trim()
                val station = mediaMetadata.station?.toString()?.trim()
                val genre = mediaMetadata.genre?.toString()?.trim()
                if (!title.isNullOrEmpty() || !artist.isNullOrEmpty() || !station.isNullOrEmpty()) {
                    val streamTitle = if (!artist.isNullOrEmpty() && !title.isNullOrEmpty() && !title.contains(artist)) {
                        "$artist - $title"
                    } else {
                        title ?: artist
                    }
                    android.util.Log.i("AuvyPlayer", "ICY onMediaMetadataChanged: title='$streamTitle' station='$station'")
                    activeChannel?.invokeMethod("onIcyMetadata", mapOf(
                        "streamTitle" to streamTitle,
                        "stationName" to station,
                        "genre" to genre
                    ))
                }
            }

            override fun onMetadata(metadata: Metadata) {
                for (i in 0 until metadata.length()) {
                    val entry = metadata.get(i)
                    if (entry is IcyInfo) {
                        val title = entry.title?.trim()
                        if (!title.isNullOrEmpty()) {
                            android.util.Log.i("AuvyPlayer", "ICY onMetadata IcyInfo: title='$title'")
                            activeChannel?.invokeMethod("onIcyMetadata", mapOf(
                                "streamTitle" to title
                            ))
                        }
                    } else if (entry is IcyHeaders) {
                        android.util.Log.i("AuvyPlayer", "ICY onMetadata IcyHeaders: name='${entry.name}' bitrate='${entry.bitrate}'")
                        activeChannel?.invokeMethod("onIcyMetadata", mapOf(
                            "stationName" to entry.name?.trim(),
                            "genre" to entry.genre?.trim(),
                            "bitrate" to if (entry.bitrate > 0) "${entry.bitrate}" else null
                        ))
                    }
                }
            }

            // GAPLESS: ExoPlayer auto-advanced from the current item to the
            // pre-buffered upcoming one. A mid-playlist transition does NOT fire
            // STATE_ENDED, so this is the gapless hand-off signal. Tell Dart so it
            // syncs its queue pointer + records the play + enqueues the NEXT
            // upcoming — instead of Dart re-loading the next track (the gap). Then
            // trim the just-finished item to keep the window at [current, next].
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Forward SEEK transitions too: advanceToUpcoming moves to the next item
                // deliberately, which raises REASON_SEEK rather than AUTO, and Dart must hear
                // about it to keep its queue in sync. An ordinary seek within a track raises
                // no transition, and seekToNextMediaItem is called from only one place.
                if ((reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO ||
                        reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK) &&
                    mediaItem != null) {
                    val vid = mediaItem.mediaId
                    android.util.Log.i("AuvyPlayer", "gapless auto-advance → $vid")
                    activeChannel?.invokeMethod("onNativeAutoAdvance", mapOf("videoId" to vid))
                    // DON'T trim the just-finished item here — mutating the
                    // playlist AT the transition instant caused a slight hitch.
                    // The trim happens mid-track in setUpcoming instead, so the
                    // gapless boundary itself is never disturbed.
                }
            }

            // The audio pipeline (and its session id) is (re)created here — rebuild
            // the Equalizer against the new session so EQ keeps working across
            // tracks. Pitch/speed live in PlaybackParameters and persist already.
            override fun onAudioSessionIdChanged(audioSessionId: Int) {
                rebuildEqualizer(audioSessionId)
                // The LoudnessEnhancer binds to the same session — re-attach it or
                // normalization silently stops after any session change.
                applyNormalization(audioSessionId)
            }
        })

        // The 2Hz position feed runs only while the playhead can move (playing, or
        // stalled while trying to play). A paused or idle player gets one final
        // update and the loop stops, so the main thread and Dart isolate can rest.
        //
        // The update is sent before deciding whether to re-post, so any trigger can
        // call startPositionTicks() and Dart always receives one current position,
        // even if the loop stops straight away (e.g. a seek while paused).
        //
        // Restarted by onIsPlayingChanged(true), any move out of IDLE in
        // onPlaybackStateChanged, and onPositionDiscontinuity. Restarting is
        // idempotent, so triggers can't stack duplicate tickers.
        positionTick = object : Runnable {
            override fun run() {
                val player = sharedPlayer
                if (player == null || player.playbackState == Player.STATE_IDLE) {
                    positionTicking = false
                    return
                }
                val dur = player.duration
                activeChannel?.invokeMethod(
                    "onPosition",
                    mapOf(
                        "positionMs" to player.currentPosition,
                        "durationMs" to (if (dur == C.TIME_UNSET) 0L else dur),
                        "bufferedMs" to player.bufferedPosition,
                        "isPlaying" to player.isPlaying
                    )
                )
                // Moving = playing, or buffering while trying to play (playWhenReady). A
                // paused player that happens to be buffering (e.g. after sleep-at-end-of-
                // track pauses mid-buffer) can't produce a new position, so it stops the
                // loop. Suppression also lands here as not playing; lifting it fires
                // onIsPlayingChanged(true), which restarts the feed.
                val moving = player.isPlaying ||
                    (player.playWhenReady &&
                        player.playbackState == Player.STATE_BUFFERING)
                if (!moving) {
                    positionTicking = false
                    // Logs when the feed stops, once per transition: it confirms the loop is
                    // really idle and timestamps each pause.
                    android.util.Log.i(
                        "AuvyPlayer",
                        "position feed idle at ${player.currentPosition}ms " +
                            "(state=${player.playbackState}, playWhenReady=${player.playWhenReady})"
                    )
                    return
                }
                mainHandler.postDelayed(this, 500)
            }
        }
        startPositionTicks()
    }

    /// Begin (or continue) the 2Hz position feed. Idempotent.
    private fun startPositionTicks() {
        if (positionTicking) return
        val tick = positionTick ?: return
        positionTicking = true
        mainHandler.post(tick)
    }

    // Build the AudioManager + AudioFocusRequest + focus-change listener ONCE
    // (called from installPlayerInfra, which itself runs once per process).
    private fun setupAudioFocus() {
        val am = appContext.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        audioManager = am
        val focusAttrs = android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val listener = android.media.AudioManager.OnAudioFocusChangeListener { change ->
            // Log every focus change before branching, so the log shows whether the
            // callback fired at all.
            android.util.Log.i("AuvyPlayer", "audiofocus change=" + change)
            mainHandler.post {
                val p = sharedPlayer ?: return@post
                when (change) {
                    // Permanent loss (another media app took full focus). Pause; the user
                    // resumes manually. Ignored during a call.
                    android.media.AudioManager.AUDIOFOCUS_LOSS -> {
                        // Clear the flag first: after a permanent loss the system has dropped our
                        // focus request, and a stale `true` would stop requestAudioFocusIfNeeded()
                        // from asking again on the next play. Cleared even when we keep playing
                        // through a call.
                        hasAudioFocus = false
                        if (isPhoneCallActive()) return@post
                        resumeOnFocusGain = false
                        if (p.playWhenReady) p.pause()
                        android.util.Log.i("AuvyPlayer", "audiofocus LOSS → pause (focus released)")
                        noteToDart("audio focus lost to another app — paused")
                    }
                    // Transient loss (nav prompt, short clip, phone call). Pause and remember
                    // to auto-resume.
                    android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                        resumeOnFocusGain = p.playWhenReady
                        // Stamped so the GAIN branch can tell a momentary
                        // interruption from the user having moved on, and so a
                        // call, which legitimately runs long — is exempt.
                        transientLossAtMs = android.os.SystemClock.elapsedRealtime()
                        lostToCall = isPhoneCallActive()
                        if (p.playWhenReady) p.pause()
                        android.util.Log.i("AuvyPlayer", "audiofocus LOSS_TRANSIENT → pause (resume=$resumeOnFocusGain call=$lostToCall)")
                        noteToDart("audio focus lost briefly" +
                            (if (lostToCall) " to a call" else "") +
                            " — paused, will resume=$resumeOnFocusGain")
                    }
                    // Duckable loss (notification sound): lower the volume and keep playing.
                    // Ignored during a call.
                    android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                        if (isPhoneCallActive()) return@post
                        p.volume = 0.2f
                    }
                    // Focus back: un-duck to the app's real volume, and resume
                    // if we paused for a transient loss.
                    android.media.AudioManager.AUDIOFOCUS_GAIN -> {
                        // Focus is genuinely ours again — record that, so a later
                        // play doesn't waste a redundant request, and so the flag
                        // can never drift from reality in the other direction.
                        hasAudioFocus = true
                        // Un-duck through normalizationVolumeScale(), not bare appVolume, so a loud
                        // track's attenuation is kept after the duck ends.
                        p.volume = appVolume * normalizationVolumeScale()
                        if (resumeOnFocusGain) {
                            resumeOnFocusGain = false
                            // Only resume if both hold:
                            //  • The loss was short (TRANSIENT_RESUME_WINDOW_MS); a call is exempt,
                            //    since people expect music back after a call.
                            //  • Nothing else is audible. We're paused, so isMusicActive() can only mean
                            //    another app is playing, and starting over it would be wrong.
                            if (shouldResumeOnFocusGain()) {
                                p.play()
                                android.util.Log.i("AuvyPlayer", "audiofocus GAIN → resume")
                                noteToDart("audio focus regained — resumed")
                            }
                        }
                    }
                    // Any other code: Android can also send GAIN_TRANSIENT and
                    // GAIN_TRANSIENT_EXCLUSIVE, and future codes land here too. A negative code is
                    // always a loss, so treat it as transient (pause, remember to resume); a
                    // positive one is a gain, so restore volume and resume if we paused.
                    else -> {
                        if (change < 0) {
                            resumeOnFocusGain = p.playWhenReady
                            // Stamped here too — an unrecognised loss is still a
                            // loss, and without this its resume would be judged
                            // against whatever the last stamp happened to be.
                            transientLossAtMs = android.os.SystemClock.elapsedRealtime()
                            lostToCall = isPhoneCallActive()
                            if (p.playWhenReady) p.pause()
                            android.util.Log.w("AuvyPlayer",
                                "audiofocus unhandled LOSS code=" + change +
                                    " → pause (resume=" + resumeOnFocusGain + ")")
                        } else {
                            hasAudioFocus = true
                            p.volume = appVolume * normalizationVolumeScale()
                            if (resumeOnFocusGain) {
                                resumeOnFocusGain = false
                                if (shouldResumeOnFocusGain()) p.play()
                            }
                            android.util.Log.i("AuvyPlayer",
                                "audiofocus unhandled GAIN code=" + change)
                        }
                    }
                }
            }
        }
        audioFocusRequest = android.media.AudioFocusRequest.Builder(
                android.media.AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(focusAttrs)
            .setOnAudioFocusChangeListener(listener, mainHandler)
            .setWillPauseWhenDucked(false) // we duck ourselves (above)
            .build()
    }

    // Best-effort "is a phone/VoIP call happening", via AudioManager.mode
    // (permission-free). Used to resume after a call and to ignore permanent
    // losses and ducking during one.
    private fun isPhoneCallActive(): Boolean {
        val mode = audioManager?.mode ?: return false
        return mode == android.media.AudioManager.MODE_IN_CALL ||
               mode == android.media.AudioManager.MODE_IN_COMMUNICATION ||
               mode == android.media.AudioManager.MODE_RINGTONE
    }

    /// Whether focus coming back should actually restart playback.
    ///
    /// Shared by BOTH gain branches: the explicit AUDIOFOCUS_GAIN one and the
    /// catch-all for unrecognised positive codes, which resumed blind. See the
    /// GAIN branch for why either condition alone is not enough.
    private fun shouldResumeOnFocusGain(): Boolean {
        val elapsed = android.os.SystemClock.elapsedRealtime() - transientLossAtMs
        val stillFresh = lostToCall || elapsed <= TRANSIENT_RESUME_WINDOW_MS
        val someoneElsePlaying = try {
            audioManager?.isMusicActive == true
        } catch (_: Exception) {
            false
        }
        if (!stillFresh || someoneElsePlaying) {
            android.util.Log.i("AuvyPlayer",
                "audiofocus GAIN → NOT resuming (elapsed=${elapsed}ms " +
                    "call=$lostToCall otherAudio=$someoneElsePlaying)")
            return false
        }
        return true
    }

    private fun requestAudioFocusIfNeeded() {
        if (hasAudioFocus) return
        val am = audioManager ?: return
        val req = audioFocusRequest ?: return
        val res = am.requestAudioFocus(req)
        hasAudioFocus = res == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        android.util.Log.i("AuvyPlayer", "requestAudioFocus → granted=$hasAudioFocus")
    }

    private fun abandonAudioFocusInternal() {
        val am = audioManager ?: return
        val req = audioFocusRequest ?: return
        am.abandonAudioFocusRequest(req)
        hasAudioFocus = false
        resumeOnFocusGain = false
    }

    private fun bindMethodHandler() {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "playVideo" -> {
                        val url = call.argument<String>("url")
                        val userAgent = call.argument<String>("userAgent") ?: DEFAULT_UA
                        val contentLength = (call.argument<Any>("contentLength") as? Number)?.toLong() ?: 0L
                        // When restoring the last track on app launch Dart passes
                        // autoPlay=false: prepare/buffer the track but DO NOT start
                        // playback, so the app opens in a paused state instead of
                        // blasting audio the instant it launches. Defaults to true
                        // for every normal user-initiated play.
                        val autoPlay = call.argument<Boolean>("autoPlay") ?: true
                        // A fully-downloaded local file (from Dart's cache). When
                        // present we play it directly: instant start, no stalls,
                        // instant seeking — no network at all.
                        val localPath = call.argument<String>("localPath")
                        val videoId = call.argument<String>("videoId") ?: ""

                        val localFile = localPath?.let { File(it) }
                        if (localFile != null && localFile.exists() && localFile.length() > 0) {
                            // Already fully on disk (Auvy's explicit-download cache) —
                            // play it directly: instant, no network, instant seeking.
                            android.util.Log.i("AuvyPlayer", "playing LOCAL cached file ($videoId)")
                            // Carry the id: once a local track can be the gapless
                            // upcoming, the item playing before it must be
                            // identifiable too, or the transition window is
                            // asymmetric.
                            player.setMediaSource(localFileSource(localFile, videoId))
                            player.playWhenReady = autoPlay
                            player.prepare()
                            result.success(null)
                        } else if (videoId.isNotEmpty() && !videoId.startsWith("http")) {
                            // YouTube track: a lazily resolving, cached source keyed by videoId (see
                            // buildResolvingSource). Seed the URL cache with what Dart already resolved
                            // so the first play needs no extra round trip.
                            // freshStart: this is a normal track start, so it replaces the mid-track
                            // format pin (see seedUrl).
                            if (url != null && url.isNotEmpty()) {
                                seedUrl(videoId, url, userAgent, contentLength,
                                    freshStart = true)
                            }
                            android.util.Log.i("AuvyPlayer", "playing RESOLVING stream ($videoId)")
                            player.setMediaSource(buildResolvingSource(videoId))
                            player.playWhenReady = autoPlay
                            player.prepare()
                            result.success(null)
                        } else if (url != null) {
                            // RADIO / direct stream (m3u8 / icecast) — a real playable URL,
                            // nothing to resolve. Play it directly.
                            player.setMediaSource(buildSource(url, userAgent, contentLength))
                            player.playWhenReady = autoPlay
                            player.prepare()
                            result.success(null)
                        } else {
                            result.error("INVALID_URL", "Stream URL is null", null)
                        }
                    }
                    "prewarmNext" -> {
                        val vid = call.argument<String>("videoId") ?: ""
                        val u = call.argument<String>("url") ?: ""
                        val ua = call.argument<String>("userAgent") ?: DEFAULT_UA
                        val clen = (call.argument<Any>("contentLength") as? Number)?.toLong() ?: 0L
                        prewarmNext(vid, u, ua, clen)
                        result.success(null)
                    }
                    "setUpcoming" -> {
                        // GAPLESS: queue the (already audio-conformed) next track as a
                        // 2nd media item so ExoPlayer pre-buffers it and transitions
                        // with ZERO gap. Dart calls this ONLY when the gapless setting
                        // is on; otherwise the single-track + prewarmNext path is used.
                        val vid = call.argument<String>("videoId") ?: ""
                        val u = call.argument<String>("url") ?: ""
                        val ua = call.argument<String>("userAgent") ?: DEFAULT_UA
                        val clen = (call.argument<Any>("contentLength") as? Number)?.toLong() ?: 0L
                        // A downloaded next track: arm it as the upcoming item too, so a downloaded
                        // album plays gaplessly.
                        val localPath = call.argument<String>("localPath")
                        if (vid.isNotEmpty() && !vid.startsWith("http")) {
                            // Trim already-FINISHED items (everything before the
                            // current) here — mid-track, so the window stays
                            // [current, upcoming] WITHOUT touching the playlist at
                            // the gapless boundary (which caused a slight hitch).
                            while (player.currentMediaItemIndex > 0) player.removeMediaItem(0)
                            val nextIdx = player.currentMediaItemIndex + 1
                            val curNextId = if (player.mediaItemCount > nextIdx)
                                player.getMediaItemAt(nextIdx).mediaId else null
                            if (curNextId != vid) {
                                // Drop any stale upcoming, then append THIS one.
                                while (player.mediaItemCount > nextIdx)
                                    player.removeMediaItem(player.mediaItemCount - 1)
                                val localFile = localPath?.let { File(it) }
                                if (localFile != null && localFile.exists() && localFile.length() > 0) {
                                    player.addMediaSource(localFileSource(localFile, vid))
                                    android.util.Log.i("AuvyPlayer", "setUpcoming ($vid) — gapless next queued from LOCAL file")
                                } else {
                                    // Seed the gapless upcoming through seedUrl too, so its format pin is set.
                                    // freshStart: this format is the one that will play.
                                    if (u.isNotEmpty()) {
                                        seedUrl(vid, u, ua, clen, freshStart = true)
                                    }
                                    player.addMediaSource(buildResolvingSource(vid))
                                    android.util.Log.i("AuvyPlayer", "setUpcoming ($vid) — gapless next queued")
                                }
                            }
                        }
                        result.success(null)
                    }
                    "advanceToUpcoming" -> {
                        // Skip to the pre-buffered upcoming track without re-preparing, so a manual
                        // skip is as gapless as a natural track end.
                        //
                        // The id is checked here because only native knows what is actually armed,
                        // and the queue may change between Dart's check and this call. On a
                        // mismatch this refuses and Dart falls back to the normal path.
                        val want = call.argument<String>("videoId") ?: ""
                        val nextIdx = player.nextMediaItemIndex
                        val armed = if (nextIdx in 0 until player.mediaItemCount)
                            player.getMediaItemAt(nextIdx).mediaId else ""
                        if (want.isEmpty() || armed != want) {
                            android.util.Log.i("AuvyPlayer",
                                "advanceToUpcoming declined: armed='$armed' wanted='$want'")
                            result.success(false)
                        } else {
                            player.seekToNextMediaItem()
                            player.play()
                            android.util.Log.i("AuvyPlayer", "advanceToUpcoming → $want (no re-prepare)")
                            result.success(true)
                        }
                    }
                    "clearUpcoming" -> {
                        // Drop the queued next item (on skip/prev/reorder/remove) so
                        // ExoPlayer doesn't gaplessly roll into a now-stale track.
                        val nextIdx = player.currentMediaItemIndex + 1
                        while (player.mediaItemCount > nextIdx)
                            player.removeMediaItem(player.mediaItemCount - 1)
                        result.success(null)
                    }
                    // Hands Dart the network bytes counted by AudioTrafficCounter since the last
                    // call, for Settings → Storage & data.
                    "drainAudioBytes" -> {
                        result.success(AudioTrafficCounter.drain())
                    }
                    "clearUrlCache" -> {
                        // Cached googlevideo URLs are bound to the IP they were resolved from, so
                        // after a Wi-Fi/mobile switch they all 403. Drop them so the next chunk
                        // fetch re-resolves on the new network.
                        songUrlCache.clear()
                        currentResolveKey = null
                        android.util.Log.i("AuvyPlayer", "clearUrlCache — dropped all cached stream URLs (network change)")
                        result.success(null)
                    }
                    "promoteFromPlayCache" -> {
                        // "Save from stream": if the WHOLE track is already in the media3 play-cache,
                        // copy those bytes into a file for the Cached/Downloads folder with no
                        // network use. Returns {promoted:true, bytes} only when the full track is
                        // cached from byte 0; otherwise {promoted:false, reason} so Dart can fall back
                        // to an HTTP download (explicit downloads) or skip it.
                        val vid = call.argument<String>("videoId") ?: ""
                        val targetPath = call.argument<String>("targetPath") ?: ""
                        val declaredLen = (call.argument<Any>("contentLength") as? Number)?.toLong() ?: 0L
                        val mainH = android.os.Handler(android.os.Looper.getMainLooper())
                        if (vid.isEmpty() || targetPath.isEmpty() || vid.startsWith("http")) {
                            result.success(mapOf("promoted" to false, "reason" to "invalid"))
                        } else {
                            Thread {
                                try {
                                    val cache = getPlayerCache(appContext)
                                    val meta = cache.getContentMetadata(vid)
                                    var total = androidx.media3.datasource.cache.ContentMetadata.getContentLength(meta)
                                    if (total <= 0) total = declaredLen
                                    if (total <= 0) {
                                        mainH.post { result.success(mapOf("promoted" to false, "reason" to "unknown-length")) }
                                        return@Thread
                                    }
                                    // Whole track cached contiguously from byte 0?
                                    val run = cache.getCachedLength(vid, 0, total)
                                    if (run < total) {
                                        mainH.post { result.success(mapOf("promoted" to false, "reason" to "partial")) }
                                        return@Thread
                                    }
                                    val source = androidx.media3.datasource.cache.CacheDataSource(cache, null)
                                    val spec = DataSpec.Builder()
                                        .setUri(Uri.parse("cache:///$vid"))
                                        .setKey(vid).setPosition(0).setLength(total).build()
                                    source.open(spec)
                                    val out = java.io.FileOutputStream(java.io.File(targetPath))
                                    val buf = ByteArray(128 * 1024)
                                    var written = 0L
                                    while (true) {
                                        val n = source.read(buf, 0, buf.size)
                                        if (n == androidx.media3.common.C.RESULT_END_OF_INPUT) break
                                        out.write(buf, 0, n); written += n
                                    }
                                    out.flush(); out.close(); source.close()

                                    // A short copy is not a promotion: a partial file would be registered as a
                                    // complete cached track and every later play would stop early. The expected
                                    // length is known, so check it exactly and delete a short file.
                                    if (written != total) {
                                        try { java.io.File(targetPath).delete() } catch (_: Exception) {}
                                        android.util.Log.w("AuvyPlayer",
                                            "promoteFromPlayCache $vid SHORT: $written of $total bytes — discarded")
                                        mainH.post { result.success(mapOf("promoted" to false, "reason" to "short-write")) }
                                        return@Thread
                                    }
                                    android.util.Log.i("AuvyPlayer", "promoteFromPlayCache $vid → $written bytes (0 network)")
                                    mainH.post { result.success(mapOf("promoted" to true, "bytes" to written)) }
                                } catch (e: Exception) {
                                    android.util.Log.w("AuvyPlayer", "promoteFromPlayCache failed for $vid: ${e.message}")
                                    try { java.io.File(targetPath).delete() } catch (_: Exception) {}
                                    mainH.post { result.success(mapOf("promoted" to false, "reason" to (e.message ?: "error"))) }
                                }
                            }.apply { isDaemon = true }.start()
                        }
                    }
                    // User-initiated pause/stop: no transition is pending, so drop any bridge
                    // locks. An explicit pause also cancels any pending focus auto-resume, so
                    // Auvy doesn't restart itself after the user chose to stop.
                    "pause" -> {
                        resumeOnFocusGain = false
                        player.pause(); releaseTransitionLocks(); result.success(null)
                    }
                    "resume" -> { player.play(); result.success(null) }
                    "stop" -> { player.stop(); releaseTransitionLocks(); abandonAudioFocusInternal(); result.success(null) }
                    "seek" -> {
                        val pos = call.argument<Int>("positionMs") ?: 0
                        player.seekTo(pos.toLong())
                        result.success(null)
                    }
                    "setVolume" -> {
                        val vol = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                        // Remember Dart's intended volume so audio-focus un-duck
                        // restores to it (not a hardcoded 1.0).
                        appVolume = vol
                        // Fold in normalization ATTENUATION (loud masters); the
                        // boost direction is handled by the LoudnessEnhancer.
                        player.volume = vol * normalizationVolumeScale()
                        result.success(null)
                    }
                    // Attached outputs, most-preferred first, one row per physical
                    // device. `isDefault` marks where audio goes with no pin set.
                    "listOutputs" -> {
                        val out = ArrayList<HashMap<String, Any?>>()
                        try {
                            val am = appContext.getSystemService(Context.AUDIO_SERVICE)
                                as android.media.AudioManager
                            // Media-routing precedence. SCO is last: it is the
                            // telephony leg of a headset that also exposes A2DP,
                            // and ranking it below means the dedupe below keeps the
                            // music-capable entry.
                            val order = listOf(
                                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                                android.media.AudioDeviceInfo.TYPE_BLE_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_BLE_SPEAKER,
                                android.media.AudioDeviceInfo.TYPE_HEARING_AID,
                                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_USB_DEVICE,
                                android.media.AudioDeviceInfo.TYPE_USB_ACCESSORY,
                                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                                android.media.AudioDeviceInfo.TYPE_DOCK,
                                android.media.AudioDeviceInfo.TYPE_BUS,
                                android.media.AudioDeviceInfo.TYPE_AUX_LINE,
                                android.media.AudioDeviceInfo.TYPE_LINE_ANALOG,
                                android.media.AudioDeviceInfo.TYPE_LINE_DIGITAL,
                                android.media.AudioDeviceInfo.TYPE_HDMI,
                                android.media.AudioDeviceInfo.TYPE_HDMI_ARC,
                                android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
                            )
                            fun kindOf(type: Int): String = when (type) {
                                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                                android.media.AudioDeviceInfo.TYPE_BLE_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_BLE_SPEAKER,
                                android.media.AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"
                                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                                android.media.AudioDeviceInfo.TYPE_AUX_LINE,
                                android.media.AudioDeviceInfo.TYPE_LINE_ANALOG,
                                android.media.AudioDeviceInfo.TYPE_LINE_DIGITAL -> "headphones"
                                android.media.AudioDeviceInfo.TYPE_USB_DEVICE,
                                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                                android.media.AudioDeviceInfo.TYPE_USB_ACCESSORY,
                                android.media.AudioDeviceInfo.TYPE_DOCK,
                                android.media.AudioDeviceInfo.TYPE_BUS -> "usb"
                                android.media.AudioDeviceInfo.TYPE_HDMI,
                                android.media.AudioDeviceInfo.TYPE_HDMI_ARC -> "hdmi"
                                android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                                // Never dropped. An unrecognised type is still a
                                // real output — a car head unit can report one —
                                // and hiding it would make the device unreachable.
                                else -> "other"
                            }

                            val sorted = am
                                .getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
                                .filter {
                                    // Exclude SCO (a headset's call audio link) and the earpiece: neither is a
                                    // music output. (Samsung reports the phone model as every built-in device's
                                    // name, so the earpiece looked like a second speaker.)
                                    it.type != android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO &&
                                    it.type != android.media.AudioDeviceInfo.TYPE_BUILTIN_EARPIECE &&
                                    it.type != android.media.AudioDeviceInfo.TYPE_TELEPHONY &&
                                    it.type != android.media.AudioDeviceInfo.TYPE_REMOTE_SUBMIX
                                }
                                .sortedBy { d ->
                                    val i = order.indexOf(d.type)
                                    if (i < 0) order.size else i
                                }

                            // One headset reports several device entries (A2DP for
                            // music, SCO for calls, LE Audio on newer stacks) and
                            // they all carry the same product name, which is why
                            // the picker listed it twice. Keeping the first per
                            // name leaves the media-capable one.
                            val seen = HashSet<String>()
                            val unique = sorted.filter {
                                val label = it.productName?.toString()?.trim() ?: ""
                                seen.add("${kindOf(it.type)}|${label.lowercase()}")
                            }
                            val defaultId = unique.firstOrNull()?.id ?: -1

                            for (d in unique) {
                                val kind = kindOf(d.type)
                                // Built-in devices report the PHONE'S MODEL as
                                // their product name ("SM-S926B"), which is not
                                // what anyone calls the speaker. Dropping any name
                                // that equals the model covers the speaker and any
                                // other built-in an OEM adds later; Dart supplies
                                // the readable name.
                                val raw = d.productName?.toString()?.trim() ?: ""
                                val label = if (kind == "speaker" ||
                                    raw.equals(android.os.Build.MODEL, ignoreCase = true) ||
                                    raw.equals(android.os.Build.DEVICE, ignoreCase = true)
                                ) "" else raw
                                out.add(hashMapOf(
                                    "id" to d.id,
                                    "name" to label,
                                    "kind" to kind,
                                    "isPreferred" to (preferredOutputId == d.id),
                                    "isDefault" to (d.id == defaultId),
                                    // A dock or automotive bus is a car, detectable without permissions. A car
                                    // stereo on plain Bluetooth can't be told apart from headphones without
                                    // BLUETOOTH_CONNECT (not requested), so it shows as a normal Bluetooth device.
                                    "isCar" to (
                                        d.type == android.media.AudioDeviceInfo.TYPE_DOCK ||
                                        d.type == android.media.AudioDeviceInfo.TYPE_BUS),
                                ))
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("AuvyPlayer", "listOutputs failed: ${e.message}")
                        }
                        result.success(out)
                    }
                    // Points THIS player at one output; id < 0 clears the preference and lets
                    // the system route. It moves only Auvy's audio, never other apps'. Device-wide
                    // changes (pairing, Cast) stay with the system dialog, which the sheet also
                    // offers.
                    "setOutput" -> {
                        val id = call.argument<Int>("id") ?: -1
                        try {
                            if (id < 0) {
                                preferredOutputId = -1
                                player.setPreferredAudioDevice(null)
                                releasePinOnDetach(false)
                                result.success(true)
                            } else {
                                val am = appContext.getSystemService(Context.AUDIO_SERVICE)
                                    as android.media.AudioManager
                                val target = am
                                    .getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
                                    .firstOrNull { it.id == id }
                                if (target == null) {
                                    // Unplugged between listing and tapping.
                                    result.success(false)
                                } else {
                                    preferredOutputId = id
                                    player.setPreferredAudioDevice(target)
                                    releasePinOnDetach(true)
                                    result.success(true)
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("AuvyPlayer", "setOutput failed: ${e.message}")
                            result.success(false)
                        }
                    }
                    "setSpeed" -> {
                        // Keep pitch when changing speed (setPlaybackSpeed forces
                        // pitch=1.0, which is why pitch never took effect before).
                        currentSpeed = call.argument<Double>("speed")?.toFloat() ?: 1.0f
                        player.playbackParameters = PlaybackParameters(currentSpeed, currentPitch)
                        result.success(null)
                    }
                    "setPitch" -> {
                        // Real pitch shift via PlaybackParameters (independent of speed).
                        currentPitch = (call.argument<Double>("pitch")?.toFloat() ?: 1.0f)
                            .coerceIn(0.25f, 4.0f)
                        player.playbackParameters = PlaybackParameters(currentSpeed, currentPitch)
                        result.success(null)
                    }
                    "setSkipSilence" -> {
                        // ExoPlayer's built-in silence trimmer (SilenceSkippingAudioProcessor in the
                        // default audio sink); this switch arms it.
                        player.skipSilenceEnabled = call.argument<Boolean>("enabled") ?: false
                        result.success(null)
                    }
                    // Throughput and stalls since the last read, for the Dart-side bitrate
                    // ladder. The stall count is read-and-clear, since the ladder asks "has
                    // anything gone wrong since I last decided?".
                    "getNetworkStats" -> {
                        val stalls = stallCount
                        stallCount = 0
                        result.success(
                            mapOf(
                                // -1 (media3's NO_ESTIMATE) is passed through
                                // rather than smoothed to 0: "I don't know yet" and
                                // "the network is dead" must not look the same, or a
                                // cold start would drop straight to the lowest tier.
                                "bitrateEstimate" to (bandwidthMeter?.bitrateEstimate ?: -1L),
                                "stalls" to stalls,
                            ))
                    }
                    "setNormalizationGain" -> {
                        // Volume-normalization gain, in millibels, derived from
                        // YouTube's own audioConfig.loudnessDb (see AudioService).
                        // Applied with a LoudnessEnhancer bound to the audio session
                        // — a real gain stage, so quiet masters are brought UP
                        // instead of only turning loud ones down (which is all a
                        // player.volume scale can do).
                        normalizationGainMb = (call.argument<Int>("gainMb") ?: 0)
                            .coerceIn(MIN_GAIN_MB, MAX_GAIN_MB)
                        normalizationEnabled = call.argument<Boolean>("enabled") ?: false
                        applyNormalization(player.audioSessionId)
                        // Re-apply the volume trim here too: a negative gain is applied as a volume
                        // trim, and Dart calls setVolume before this, so recomputing only in
                        // setVolume would apply the previous track's gain. This keeps gain and trim
                        // in step whatever the call order.
                        player.volume = appVolume * normalizationVolumeScale()
                        result.success(null)
                    }
                    "setEqualizer" -> {
                        eqEnabled = call.argument<Boolean>("enabled") ?: false
                        val bands = call.argument<List<Double>>("bands")
                        if (bands != null) {
                            for (i in 0 until minOf(5, bands.size)) eqBandsDb[i] = bands[i].toFloat()
                        }
                        val eq = equalizer
                        if (eq == null) {
                            rebuildEqualizer(player.audioSessionId)
                        } else {
                            applyBandsTo(eq)
                            eq.enabled = eqEnabled
                        }
                        result.success(null)
                    }
                    // Is any app currently playing music on this device?
                    //
                    // Guards against misrouted media buttons: a multipoint Bluetooth headset
                    // sends PLAY over both links, so pressing play for a PC can also start Auvy
                    // on the phone (and Android 11+ media resumption may even restart the app to
                    // deliver it). `AudioManager.isMusicActive()` is device-wide and
                    // permission-free: if music is already playing and it isn't us, the PLAY
                    // wasn't for us.
                    "isMusicActive" -> {
                        val am = audioManager
                            ?: (appContext.getSystemService(Context.AUDIO_SERVICE)
                                    as android.media.AudioManager).also { audioManager = it }
                        result.success(am.isMusicActive)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("PLAYER_ERROR", e.message, null)
            }
        }
    }

    // Local (file://) playback — ExoPlayer reads straight off disk, so there are
    // no network stalls and seeking anywhere in the track is instant.
    /**
     * A downloaded file as a media source.
     *
     * Always pass [mediaId] (the videoId): onMediaItemTransition reports it to
     * Dart, which matches it against the queue to recognise a gapless advance.
     */
    private fun localFileSource(file: File, mediaId: String = ""): MediaSource {
        val factory = DefaultDataSource.Factory(appContext)
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(file))
            .setMediaId(mediaId)
            .build()
        return ProgressiveMediaSource.Factory(factory).createMediaSource(item)
    }

    // ExoPlayer's default policy re-runs a failed load ~3 more times on the SAME
    // URL. For googlevideo 403/410 that URL is dead (expired / IP-bound) and
    // ChunkedDataSource has ALREADY ridden out transient bursts internally, so
    // each outer retry just burns 10-30s of silence before Dart ever hears about
    // the error and can resolve a FRESH URL. Surface those immediately.
    private val failFastOn403 = object : DefaultLoadErrorHandlingPolicy() {
        override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
            val cause = loadErrorInfo.exception
            if (cause is HttpDataSource.InvalidResponseCodeException &&
                (cause.responseCode == 403 || cause.responseCode == 410)) {
                return C.TIME_UNSET
            }
            return super.getRetryDelayMsFor(loadErrorInfo)
        }
    }

    /// Seed [songUrlCache] for [videoId] and record the format pin, in one place.
    ///
    /// Every seed site (playTrack, setUpcoming, prewarmNext, the lazy resolve)
    /// must also record `inUseContentLength` (the mid-track format pin) and check
    /// the play-cache for another format's bytes, so they all go through here.
    ///
    /// [freshStart]: a track (re)starting, which replaces the pin (or clears it
    /// when no length is known, so a stale pin can't outlive its format). False
    /// for a lazy mid-track resolve, which must never overwrite an existing pin.
    ///
    /// Returns the entry actually stored.
    private fun seedUrl(
        videoId: String,
        url: String,
        userAgent: String,
        contentLength: Long,
        freshStart: Boolean,
    ): UrlEntry {
        // Recover the length from the URL's `&clen=` when Dart doesn't supply one
        // (ANDROID audio formats often omit contentLength). Without it both format
        // safeguards are blind: the pin is cleared and the mismatch check is
        // skipped.
        val clen = if (contentLength > 0L) contentLength
            else Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.getOrNull(1)?.toLongOrNull() ?: 0L
        // A track (re)starting is the only safe moment to drop another format's
        // bytes, and it must run before the pin below is overwritten, since the old
        // pin is one of the two inputs.
        if (freshStart) reconcileCacheFormat(videoId, clen)
        val entry = UrlEntry(url, userAgent, clen, expiryFromUrl(url))
        songUrlCache[videoId] = entry
        if (freshStart) {
            if (clen > 0L) inUseContentLength[videoId] = clen
            else inUseContentLength.remove(videoId)
        } else if (clen > 0L) {
            inUseContentLength.putIfAbsent(videoId, clen)
        }
        pruneCaches()
        return entry
    }

    /// Keep the two static url maps finite. Called on every seed, which is the only
    /// place either one grows.
    private fun pruneCaches() {
        // Never evict the streaming track's entry: losing it would also make its
        // format pin eligible for the sweep below, allowing a mid-track format switch.
        val keep = currentResolveKey
        if (songUrlCache.size > MAX_URL_CACHE) {
            val now = System.currentTimeMillis()
            // An expired url is pure dead weight: resolveUrlBlocking rejects it and
            // re-resolves anyway, so dropping it costs nothing at all.
            songUrlCache.entries.removeIf { it.key != keep && it.value.expiresAtMs <= now }
            val over = songUrlCache.size - MAX_URL_CACHE
            if (over > 0) {
                // Still over — shed the nearest to expiry, i.e. the ones with least
                // remaining use. remove(key, value) so a concurrent re-seed of the
                // same id is never clobbered.
                songUrlCache.entries
                    .filter { it.key != keep }
                    .sortedBy { it.value.expiresAtMs }
                    .take(over)
                    .forEach { songUrlCache.remove(it.key, it.value) }
            }
        }
        if (inUseContentLength.size > MAX_PIN_CACHE) {
            // Pins aren't pruned by expiry and don't simply follow songUrlCache: the
            // 403 path removes the URL entry but keeps the pin, which tells Dart which
            // format to return. So only pins with no live URL that aren't currently
            // resolving are dropped (songUrlCache's lower cap guarantees there are some).
            inUseContentLength.entries.removeIf {
                it.key != keep && !songUrlCache.containsKey(it.key)
            }
        }
    }

    /// Drop the play-cache for [videoId] when the bytes on disk belong to a
    /// DIFFERENT audio format than the one about to play.
    ///
    /// All formats of a track share one cache key (customCacheKey = videoId), and
    /// the format a track resolves to can vary (quality setting, network, stream
    /// client), so one song can collect byte ranges from two different files.
    /// CacheDataSource then requests ranges based on those mixed spans, which
    /// googlevideo refuses (always at the same offset), and where it doesn't
    /// refuse it splices two encodings into one stream.
    ///
    /// Auvy records the format's length under its own metadata key rather than
    /// trusting media3's KEY_CONTENT_LENGTH (the 1 MB prewarm request might be
    /// recorded as the length). Its own key also survives restarts, which
    /// matters because the wrong-format bytes usually come from an earlier session.
    private fun reconcileCacheFormat(videoId: String, contentLength: Long) {
        if (contentLength <= 0L) return
        try {
            val cache = getPlayerCache(appContext)
            val onDisk = cache.getContentMetadata(videoId).get(META_FORMAT_CLEN, 0L)
            // The in-session pin is a second witness for a cache whose metadata
            // write did not land. Read BEFORE seedUrl overwrites it.
            val pinned = inUseContentLength[videoId] ?: 0L
            val mismatch = (onDisk > 0L && onDisk != contentLength) ||
                (pinned > 0L && pinned != contentLength)
            if (mismatch && cache.getCachedBytes(videoId, 0, Long.MAX_VALUE) > 0L) {
                android.util.Log.w(
                    "AuvyPlayer",
                    "format changed for $videoId (onDisk=$onDisk pinned=$pinned " +
                        "now=$contentLength) — dropping mixed play-cache")
                // Takes the metadata with it, which is why the record below happens
                // after, not before.
                cache.removeResource(videoId)
            }
            cache.applyContentMetadataMutations(
                videoId,
                ContentMetadataMutations().set(META_FORMAT_CLEN, contentLength),
            )
        } catch (e: Exception) {
            // Correctness maintenance, not a precondition: if the spans are locked by
            // an in-flight read, behave as before rather than tear a resource out
            // from under the loader.
            android.util.Log.w(
                "AuvyPlayer",
                "cache format reconcile skipped for $videoId: " +
                    "${e.javaClass.simpleName} ${e.message}")
        }
    }

    // LAZY URL resolution
    // Resolve the stream URL for [videoId]: reuse the un-expired cached URL, else
    // ask Dart (blocking — this runs on ExoPlayer's loader thread, exactly where
    // a blocking resolve belongs) for a fresh one and cache it by its own expiry.
    // Returns null only when Dart can't resolve (offline / dead) → the resolver
    // throws → the load-error policy retries (riding out a Doze radio cut).
    private fun resolveUrlBlocking(videoId: String): UrlEntry? {
        songUrlCache[videoId]?.let {
            if (it.expiresAtMs > System.currentTimeMillis() + 10_000L) return it
        }
        val latch = CountDownLatch(1)
        val holder = arrayOfNulls<UrlEntry>(1)
        mainHandler.post {
            val ch = activeChannel
            if (ch == null) { latch.countDown(); return@post }
            // Ask Dart for the SAME format, not just a fresh URL. A different itag is a
            // different file with a different length and byte layout, so continuing
            // mid-file from another format would 403 and loop. expectContentLength tells
            // Dart this is a mid-track re-resolve and it must not rotate clients.
            val expectClen = inUseContentLength[videoId] ?: 0L
            ch.invokeMethod(
                "resolveStream",
                mapOf("videoId" to videoId, "expectContentLength" to expectClen),
                object : MethodChannel.Result {
                    override fun success(res: Any?) {
                        (res as? Map<*, *>)?.let { m ->
                            val u = m["url"] as? String
                            if (!u.isNullOrEmpty()) {
                                val clen = (m["contentLength"] as? Number)?.toLong()
                                    ?: (m["contentLength"] as? String)?.toLongOrNull() ?: 0L
                                holder[0] = UrlEntry(
                                    u,
                                    (m["userAgent"] as? String)?.takeIf { it.isNotEmpty() } ?: DEFAULT_UA,
                                    clen,
                                    expiryFromUrl(u),
                                )
                            }
                        }
                        latch.countDown()
                    }
                    override fun error(code: String, msg: String?, details: Any?) { latch.countDown() }
                    override fun notImplemented() { latch.countDown() }
                },
            )
        }
        try {
            latch.await(20, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        val resolved = holder[0] ?: return null
        // The URL just resolved defines the format later re-resolves must match. It
        // is recorded only when absent (freshStart = false) because this is a
        // mid-track resolve.
        //
        // Returns the STORED entry, not `resolved`: priming marks the cached instance,
        // and a detached copy would lose that flag and re-prime on every chunk.
        return seedUrl(
            videoId, resolved.url, resolved.userAgent, resolved.contentLength,
            freshStart = false,
        )
    }

    // Load-error policy shared by every resolving source: keep playback alive
    // across the two screen-off failure modes instead of surfacing a fatal error.
    private val resilientPolicy = object : DefaultLoadErrorHandlingPolicy() {
        // Retry generously so a Doze radio cut / CDN gate rides out before the
        // player gives up (then Dart's heal is the last-resort fallback).
        override fun getMinimumLoadableRetryCount(dataType: Int): Int = 12

        override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
            val cause = info.exception
            // 403/410: the URL is stale / IP-bound (Samsung Wi-Fi flap gave a new
            // egress IP). Drop it so the retry re-resolves a FRESH URL via Dart.
            if (cause is HttpDataSource.InvalidResponseCodeException &&
                (cause.responseCode == 403 || cause.responseCode == 410)) {
                // Always log the first line of each 403, before anything can return: the
                // full "403 DETAIL" dump below only runs when errorCount == 1, which a burst
                // of retries can skip. Values are URL parameters and byte offsets only (no
                // titles, queries or identity), so it's safe in release builds.
                try {
                    val ds0 = cause.dataSpec
                    val u0 = ds0.uri
                    fun p(k: String) = u0.getQueryParameter(k)
                    android.util.Log.w(
                        "AuvyPlayer",
                        "403 PROBE n=${info.errorCount} code=${cause.responseCode} " +
                            "pos=${ds0.position} len=${ds0.length} " +
                            "itag=${p("itag")} clen=${p("clen")} urlRange=${p("range")} " +
                            "hasPot=${p("pot") != null} hasN=${p("n") != null} " +
                            "expire=${p("expire")} now=${System.currentTimeMillis() / 1000} " +
                            "host=${u0.host}")
                } catch (e: Exception) {
                    android.util.Log.w(
                        "AuvyPlayer", "403 PROBE unavailable: ${e.javaClass.simpleName}")
                }
                // Is the URL we're holding actually stale? A 403 doesn't imply an expired
                // URL, and throwing away a still-valid URL means each retry gets a fresh one
                // that has never served bytes, which googlevideo can refuse for a mid-file
                // range. So retry the SAME URL first, and only re-resolve once same-URL
                // retries have failed or the URL really has expired.
                val key = currentResolveKey
                val cached = key?.let { songUrlCache[it] }
                val urlStillValid =
                    cached != null && cached.expiresAtMs > System.currentTimeMillis() + 10_000L
                val escalateToFreshUrl =
                    !urlStillValid || info.errorCount > SAME_URL_403_RETRIES
                if (escalateToFreshUrl) key?.let { songUrlCache.remove(it) }
                // Bounded: past getMinimumLoadableRetryCount this falls through to super,
                // which ends retries and hands over to Dart's error recovery, so a track whose
                // fresh URLs also 403 can't retry forever.
                //
                // On the first 403, log everything needed to diagnose it (at W, so it
                // survives release builds):
                //   • pos/len     → the byte offset it failed at
                //   • urlRange    → a range bound baked into the URL
                //   • hasPot/hasN → whether proof-of-origin / n parameters are present
                //   • expire/now  → whether the URL had expired
                //   • itag/clen   → which format, and the length it claims
                if (info.errorCount <= getMinimumLoadableRetryCount(C.DATA_TYPE_MEDIA)) {
                    if (info.errorCount == 1) {
                        try {
                            val ds = cause.dataSpec
                            val u = ds.uri
                            fun q(k: String) = u.getQueryParameter(k)
                            android.util.Log.w(
                                "AuvyPlayer",
                                "403 DETAIL pos=${ds.position} len=${ds.length} " +
                                    "itag=${q("itag")} clen=${q("clen")} urlRange=${q("range")} " +
                                    "hasPot=${q("pot") != null} hasN=${q("n") != null} " +
                                    "expire=${q("expire")} now=${System.currentTimeMillis() / 1000} " +
                                    "chunk=$CHUNK_LENGTH sessionChunk=${ChunkedDataSource.sessionChunkSize} " +
                                    "host=${u.host}"
                            )
                            // Dump the cache spans too: a request length that matches neither the chunk
                            // size nor clen usually means CacheDataSource is filling a hole between
                            // cached regions.
                            val c = getPlayerCache(appContext)
                            val k2 = currentResolveKey
                            if (k2 != null) {
                                android.util.Log.w(
                                    "AuvyPlayer",
                                    "403 CACHE key=$k2 cachedBytes=${c.getCachedBytes(k2, 0, Long.MAX_VALUE)} " +
                                        "holeAt=${c.getCachedLength(k2, ds.position, CHUNK_LENGTH)} " +
                                        "spans=${c.getCachedSpans(k2).joinToString { s -> "${s.position}+${s.length}" }}"
                                )
                            }
                            // Log the CDN's response headers (they often state the reason).
                            // headerFields can be null, and HttpURLConnection's map contains a NULL key
                            // (the status line), so iterate entries rather than destructuring
                            // (component1() would throw on the null key).
                            val headers = cause.headerFields
                            if (headers.isNullOrEmpty()) {
                                android.util.Log.w("AuvyPlayer", "403 HDR <none on exception>")
                            } else {
                                val wanted = setOf(
                                    "x-restrict-formats-hint", "content-type",
                                    "x-walled-garden", "content-length", "server",
                                    "x-bandwidth-est", "www-authenticate", "date",
                                    // Added: googlevideo names a range refusal here.
                                    "content-range", "accept-ranges", "x-content-type-options")
                                for (e in headers.entries) {
                                    val hk = e.key ?: continue // the status-line entry
                                    if (hk.lowercase() in wanted) {
                                        android.util.Log.w("AuvyPlayer", "403 HDR $hk=${e.value}")
                                    }
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.w(
                                "AuvyPlayer",
                                "403 DETAIL unavailable: ${e.javaClass.simpleName} ${e.message}")
                        }
                    }
                    // Back off when fresh URLs keep failing: googlevideo ties a URL to the IP
                    // that fetched it, so while the network path is changing (e.g. a Wi-Fi/LTE
                    // flap) every new URL arrives already dead. The first escalation stays fast
                    // (an expired URL is the common case); each further one doubles. errorCount
                    // resets when a load succeeds, so no extra state is needed.
                    val escalations =
                        (info.errorCount - SAME_URL_403_RETRIES).coerceAtLeast(0)
                    // Cap the number of escalations as well as the delay, so a track that's
                    // genuinely blocked gives up after ~5.5s (three escalations of 0.5s + 1s + 2s
                    // on top of the same-URL retries) and Dart can move on.
                    if (escalations > MAX_403_ESCALATIONS) {
                        android.util.Log.w(
                            "AuvyPlayer",
                            "403/410 — $escalations fresh-url attempts all refused, " +
                                "FATAL, handing to Dart (try ${info.errorCount})")
                        // C.TIME_UNSET, NOT super. See the note at the other
                        // give-up below — delegating to super does not stop
                        // anything.
                        return C.TIME_UNSET
                    }
                    val delayMs =
                        if (escalations <= 1) 500L
                        else minOf(500L shl (escalations - 1), 2_000L)
                    android.util.Log.w(
                        "AuvyPlayer",
                        if (escalateToFreshUrl)
                            "403/410 on chunk — url expired or same-url retries spent, " +
                                "re-resolving in ${delayMs}ms (try ${info.errorCount})"
                        else
                            "403/410 on chunk — url still valid, RETRYING SAME URL (try ${info.errorCount})")
                    return delayMs
                }
                // Return C.TIME_UNSET to stop retrying; any other value (including super's)
                // is a delay before another attempt. This lets Dart recover promptly.
                android.util.Log.w("AuvyPlayer", "403/410 persisted past ${info.errorCount} tries — FATAL, letting Dart heal")
                // The moment a track stops being playable natively. Rare, and
                // the direct cause of a heal or a skip the listener notices.
                noteToDart("stream refused after ${info.errorCount} retries — handing back to Dart to heal")
                return C.TIME_UNSET
            }
            // Connectivity fault (radio asleep under Doze): the URL is fine — keep
            // retrying the SAME range, waiting for the radio to wake.
            if (ChunkedDataSource.isConnectivityError(cause)) {
                android.util.Log.w("AuvyPlayer", "network outage on chunk — waiting for radio (try ${info.errorCount})")
                // Only on the first attempt: this retries every couple of seconds while
                // the radio is asleep, and a note per retry would be exactly the per-tick
                // traffic noteToDart must avoid.
                if (info.errorCount == 1) {
                    noteToDart("chunk stalled — radio asleep, waiting for the network")
                }
                return minOf(2000L * info.errorCount.toLong(), 8000L)
            }
            return super.getRetryDelayMsFor(info)
        }
    }

    private fun createResolvingDataSourceFactory(): DataSource.Factory {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(15000)
            .setDefaultRequestProperties(mapOf("Connection" to "keep-alive"))
            // Attached to the HTTP factory, not to the cache one wrapping it:
            // this is the only layer where every byte is a byte actually spent.
            // See AudioTrafficCounter.
            .setTransferListener(AudioTrafficCounter)

        // CacheDataSource writes streamed bytes into the LRU play-cache (so
        // replays / re-buffers read from disk) and falls back to upstream on a
        // cache error. Only caches what actually streams — no speculative fetch.
        val cacheFactory = CacheDataSource.Factory()
            .setCache(getPlayerCache(appContext))
            .setUpstreamDataSourceFactory(httpFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

        return ResolvingDataSource.Factory(cacheFactory) { dataSpec ->
            val key = dataSpec.key ?: return@Factory dataSpec
            val cache = getPlayerCache(appContext)
            // Next 512 KB already on disk? Serve from cache — no URL, no network.
            if (cache.isCached(key, dataSpec.position, CHUNK_LENGTH)) {
                return@Factory dataSpec.subrange(dataSpec.uriPositionOffset, CHUNK_LENGTH)
            }
            currentResolveKey = key
            val entry = resolveUrlBlocking(key)
                ?: throw java.io.IOException("No stream URL for $key (resolve failed)")
            dataSpec
                .withUri(Uri.parse(entry.url))
                .subrange(dataSpec.uriPositionOffset, CHUNK_LENGTH)
                .withAdditionalHeaders(mapOf("User-Agent" to entry.userAgent))
        }
    }

    // Pre-warm the next track: seed its URL + pull its first ~1 MB into the
    // play-cache on a background thread, so when the queue advances to it the
    // resolving source serves the opening bytes from cache immediately (no
    // resolve, no network round-trip) — a near-instant transition.
    private fun prewarmNext(videoId: String, url: String, userAgent: String, contentLength: Long) {
        if (videoId.isEmpty() || url.isEmpty() || videoId.startsWith("http")) return
        // Stop the previous prewarm FIRST. The seed below may drop this key's cached
        // spans (reconcileCacheFormat), and doing that while an earlier CacheWriter
        // is still writing the same key is the one way that purge could race a live
        // writer instead of merely being skipped.
        prewarmThread?.interrupt()
        // freshStart: this is the format the track is about to play, so it REPLACES
        // any pin left over from a previous play of it.
        seedUrl(videoId, url, userAgent, contentLength, freshStart = true)
        val t = Thread {
            try {
                val cache = getPlayerCache(appContext)
                if (cache.isCached(videoId, 0, PREWARM_BYTES)) return@Thread
                val cacheFactory = CacheDataSource.Factory()
                    .setCache(cache)
                    .setUpstreamDataSourceFactory(
                        DefaultHttpDataSource.Factory()
                            .setAllowCrossProtocolRedirects(true)
                            .setConnectTimeoutMs(15000)
                            .setReadTimeoutMs(15000)
                            .setDefaultRequestProperties(
                                mapOf("Connection" to "keep-alive", "User-Agent" to userAgent)
                            )
                            // The pre-warm pull is real data — roughly a
                            // megabyte per upcoming track, spent whether or not
                            // the listener ever reaches it.
                            .setTransferListener(AudioTrafficCounter),
                    )
                    .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
                val spec = DataSpec.Builder()
                    .setUri(Uri.parse(url))
                    .setKey(videoId)
                    .setPosition(0)
                    .setLength(PREWARM_BYTES)
                    .build()
                androidx.media3.datasource.cache.CacheWriter(
                    cacheFactory.createDataSource(), spec, null, null,
                ).cache()
                android.util.Log.i("AuvyPlayer", "prewarmed next $videoId (~${PREWARM_BYTES / 1024}KB)")
            } catch (_: InterruptedException) {
            } catch (e: Exception) {
                android.util.Log.w("AuvyPlayer", "prewarm failed for $videoId: ${e.message}")
            }
        }
        t.isDaemon = true
        prewarmThread = t
        t.start()
    }

    // A YouTube track as a lazily-resolving, cached, self-healing source. The
    // MediaItem URI is just the videoId placeholder — the ResolvingDataSource
    // swaps in the real URL per chunk; customCacheKey keys the play-cache.
    private fun buildResolvingSource(videoId: String): MediaSource {
        val mediaItem = MediaItem.Builder()
            .setMediaId(videoId)
            .setUri(videoId)
            .setCustomCacheKey(videoId)
            .build()
        return ProgressiveMediaSource.Factory(createResolvingDataSourceFactory())
            .setLoadErrorHandlingPolicy(resilientPolicy)
            .createMediaSource(mediaItem)
    }

    private fun buildSource(url: String, userAgent: String, contentLength: Long): MediaSource {
        val requestProps = mutableMapOf("Connection" to "keep-alive")
        if (contentLength <= 0L && !url.contains(".m3u8", ignoreCase = true)) {
            requestProps["Icy-MetaData"] = "1"
        }
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(15000)
            .setDefaultRequestProperties(requestProps)
            // Covers all three shapes this factory ends up in — the chunked
            // source below, open-ended icecast, and HLS radio. A listener
            // added here rides along into each, so none of them can be the
            // path that quietly goes uncounted.
            .setTransferListener(AudioTrafficCounter)

        // Bound every Range request to the known content length: googlevideo can
        // return 403 for open-ended ranges (bytes=N-), which ExoPlayer sends by
        // default, but serves bytes=N-END.
        //
        // ANDROID audio formats often omit `contentLength` (it arrives as 0), so fall
        // back to the URL's own `&clen=` parameter rather than an unbounded request.
        val clen = if (contentLength > 0) contentLength
            else Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.getOrNull(1)?.toLongOrNull() ?: 0L

        android.util.Log.i("AuvyPlayer", "buildSource arg=$contentLength clen=$clen chunked=${clen > 0} host=${Uri.parse(url).host}")

        val uri = Uri.parse(url)

        // Live HLS radio (.m3u8): progressive playback can't parse a playlist, so
        // these stations failed. Route them through HlsMediaSource with live speed adjustment
        // so ExoPlayer smoothly prevents buffer starvation.
        if (clen <= 0L && url.contains(".m3u8", ignoreCase = true)) {
            android.util.Log.i("AuvyPlayer", "buildSource HLS live stream host=${uri.host}")
            val liveItem = MediaItem.Builder()
                .setUri(uri)
                .setLiveConfiguration(
                    MediaItem.LiveConfiguration.Builder()
                        .setMaxPlaybackSpeed(1.02f)
                        .setMinPlaybackSpeed(0.98f)
                        .build()
                )
                .build()
            return HlsMediaSource.Factory(httpFactory).createMediaSource(liveItem)
        }

        val factory: DataSource.Factory = if (clen > 0) {
            // 512 KB bounded chunks — big enough to stream smoothly, small enough that a
            // skip abandons little.
            // On the un-throttled VISIONOS/ANDROID_VR URLs these are served fast and
            // ExoPlayer never starves. ChunkedDataSource still adaptively shrinks if
            // a size 403s on a DPI-gated network, so it self-heals either way.
            DataSource.Factory { ChunkedDataSource(httpFactory.createDataSource(), 512L * 1024, clen) }
        } else {
            // No known length (live icecast/direct stream) — open-ended HTTP.
            httpFactory
        }

        val mediaSourceFactory = ProgressiveMediaSource.Factory(factory)
            .setLoadErrorHandlingPolicy(failFastOn403)

        return mediaSourceFactory.createMediaSource(MediaItem.fromUri(uri))
    }
}

