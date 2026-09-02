package com.auvy.app

import android.content.Context
import android.net.Uri
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
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
        // THE single, process-wide ExoPlayer. Created once and reused for the
        // life of the process, across every FlutterEngine / Activity recreation
        // (rotation, returning from background, theme change). Previously each
        // NativePlayerManager built its OWN ExoPlayer and the old one was never
        // released, so after a recreation TWO players were alive and the next
        // track started on the new one while the old kept playing the previous
        // track underneath it. That was the "two songs overlapping" bug.
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
        private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

        // "Pause when muted" watcher
        // Turning the volume to zero is a clear "stop" gesture, but Android does
        // NOT pause for it — playback keeps running (and keeps burning data and
        // battery) into silence. This watches the MEDIA stream and tells Dart the
        // moment it hits 0.
        //
        // The PAUSE itself is done in Dart (`togglePlay(haptic: false)`), never
        // here: automated pause/resume has to go through the notifier so state,
        // the media session and the notification stay consistent.
        //
        // Installed ONCE per process (`volumeWatcher != null` guard) — a second
        // observer after an activity recreation would fire duplicate callbacks.
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

        // Track-transition bridge locks
        // Queue advance is driven from DART: ENDED → method channel → resolve
        // the next stream URL (network) → playVideo. With the screen off, the
        // moment ENDED fires ExoPlayer's own wake lock (WAKE_MODE_NETWORK) is
        // released and the CPU/WiFi are free to suspend, so the Dart advance
        // (and its network resolve) never ran until the user woke the device:
        // "playback stops when the current song ends until I open the app".
        // These timed locks bridge exactly that gap; released the moment the
        // next track actually starts (STATE_READY) or after 90s at worst.
        @Volatile private var transitionWake: android.os.PowerManager.WakeLock? = null
        @Volatile private var transitionWifi: android.net.wifi.WifiManager.WifiLock? = null
        private val transitionRelease = Runnable { releaseTransitionLocks() }

        // App-managed audio focus
        // ExoPlayer is built with handleAudioFocus=FALSE (so music plays DURING
        // a phone call — a deliberate choice). The cost was that Auvy ALSO never
        // yielded to OTHER media apps, so opening Instagram/YouTube/etc. left
        // both playing (the user's "sometimes doesn't pause" bug — it was never
        // reliable because Auvy simply wasn't participating in audio focus).
        // We now request focus ourselves and pause/duck/resume on focus changes,
        // with ONE exception: a focus loss caused by a phone call is ignored, so
        // the play-during-call behaviour is preserved. Best-effort call detection
        // via AudioManager.mode (permission-free).
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
        /// How long a transient loss may last and still be treated as one.
        ///
        /// A nav prompt, a notification beep or a short clip is over in seconds.
        /// Instagram — the reported case — takes transient focus per reel and
        /// releases it in the gaps, so anything longer than this is the user
        /// having moved on to another app, not a momentary interruption.
        private const val TRANSIENT_RESUME_WINDOW_MS = 60_000L
        // The volume Dart last asked for (fade-in ramp / user setting). Focus
        // ducking drops to 0.2 then restores to THIS, so we never fight Dart's
        // volume state.
        @Volatile private var appVolume = 1.0f

        // Adaptive bitrate: the measurements Dart decides from
        /// media3's throughput estimator. See where it is built for why we hold it.
        @Volatile private var bandwidthMeter:
            androidx.media3.exoplayer.upstream.DefaultBandwidthMeter? = null

        /// Mid-track buffer underruns since the counter was last read.
        ///
        /// MID-TRACK ONLY. Every track START buffers — that is loading, not a
        /// stall, so counting all BUFFERING transitions would report a permanently
        /// struggling network and pin quality to the floor on a perfect connection.
        /// Only a stall that happens after playback is genuinely under way counts.
        @Volatile private var stallCount = 0

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

        // LIVE streaming resilience
        // The player is NEVER handed a fixed URL. Instead a ResolvingDataSource
        // resolves the stream URL LAZILY, per byte-range, from this expiry-keyed
        // cache, and re-resolves via Dart when it expires / 403s / the egress IP
        // changes (Samsung Wi-Fi flap under Doze). A media3 SimpleCache underneath
        // writes bytes AS THEY STREAM, so replays/re-buffers read from disk. This
        // replaces the old "Dart resolves a fixed URL → playVideo(url)" flow that
        // died whenever that URL went stale.
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

        /// BOTH MAPS ARE STATIC AND WERE UNBOUNDED — a slow leak for the whole
        /// process life, not just an Activity's. Nothing evicted from songUrlCache
        /// except a network change and the 403 escalation path, so an ordinary
        /// evening of listening accumulated one entry per track played, and a
        /// googlevideo url plus its user-agent is roughly 1.5 KB of that.
        ///
        /// Only the playing track and the armed upcoming are ever read, so these
        /// caps are enormous by comparison — they exist to make the ceiling FINITE,
        /// not to ration anything. See pruneCaches for why the two differ.
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
                // cacheDir, NOT filesDir
                //
                // This is a pure LRU streaming buffer: bytes that happened to be
                // played, nothing the user asked to keep. Living in `filesDir` it
                // counted as app DATA in Android's storage screen, so up to 512 MB
                // of throwaway stream bytes were reported alongside the user's real
                // library — reported as "the app is retaining data too fast
                // (not the cache), around 1.5 GB". It was cache; it was just in the
                // wrong folder to be labelled as such.
                //
                // In `cacheDir` it is reported as Cache, "Clear cache" actually
                // clears it, and Android may reclaim it under storage pressure —
                // all correct for data that is re-downloadable by definition.
                //
                // The DART audio cache (AudioCacheManager, app documents dir)
                // deliberately stays in DATA: it holds tracks the user chose to keep
                // offline, and the OS silently deleting those would be data loss.
                //
                // A migration is unnecessary — a moved LRU cache simply starts cold
                // and refills from the network. The old directory is deleted below
                // so the stale copy does not sit there forever.
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
    /// getter, so this is the only record of the choice and the picker's ticks
    /// depend on it.
    /// SHARED, NOT PER-INSTANCE. It describes the SHARED ExoPlayer, so keeping
    /// it on the instance let an engine reattach build a new manager reading -1
    /// while the player was still pinned — the picker then showed nothing
    /// selected while audio was going somewhere else.
    private var preferredOutputId: Int
        get() = sharedPreferredOutputId
        set(value) { sharedPreferredOutputId = value }

    private var outputDetachWatcher: android.media.AudioDeviceCallback? = null

    /// Registered only while the output picker is open. See "watchOutputs".
    private var outputWatcher: android.media.AudioDeviceCallback? = null

    private fun notifyOutputsChanged() {
        try {
            activeChannel?.invokeMethod("outputsChanged", null)
        } catch (_: Exception) {
        }
    }

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
                .setBufferDurationsMs(30_000, 120_000, 2_500, 5_000)
                .setBackBuffer(30_000, true)
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
            // handleAudioFocus=false: ExoPlayer does NOT request system audio
            // focus, so it plays even while a phone call holds the focus LOCK
            // (USAGE_VOICE_COMMUNICATION / GAIN_TRANSIENT). This is what lets music
            // play DURING a call. Trade-off: Auvy no longer auto-pauses/ducks when
            // OTHER apps grab focus (other media apps, nav prompts, notifications)
            // — that's now app-managed. setHandleAudioBecomingNoisy still pauses on
            // headphone / BT unplug.
            // WAKE_MODE_NETWORK: hold a partial wake lock + WiFi lock WHILE
            // PLAYING remote streams. Without it the CPU/WiFi power-save with
            // the screen off, the buffer refill starves and playback hiccups
            // ("stops for a sec and continues"), and long tracks could stall
            // outright once the 2-minute buffer drained.
            // An explicit bandwidth meter, because Dart needs to read it.
            //
            // ExoPlayer builds a DefaultBandwidthMeter internally either way, but
            // that instance is not reachable from here, and quality selection
            // happens in Dart, at resolve time, which is the only moment a
            // different format can still be chosen. Holding the meter ourselves is
            // what turns "wifi or mobile?" (a poor proxy: weak Wi-Fi is worse than
            // good 5G) into an actual measured throughput number.
            //
            // Singleton per process: the estimate is a sliding window over real
            // transfers, so a fresh meter per player would start from the generic
            // country default and re-learn the network each time.
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
                if (playWhenReady) requestAudioFocusIfNeeded()
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
                // A stall was invisible to the app until now.
                //
                // BUFFERING was logged here and nowhere else — Dart had no signal
                // for it at all. So when a track stalled mid-load the media session
                // still read PLAYING with a frozen position, and the UI showed a
                // playing track making no sound. Observed live during a Wi-Fi flap:
                // twelve seconds of that, which is indistinguishable from the app
                // being broken, and the natural response is to hit skip — which
                // restarts the whole load and makes it worse.
                //
                // Forwarding it lets Dart say "reconnecting" instead of lying.
                // Ordinary track starts buffer briefly too, so the DECISION about
                // whether this is worth showing belongs on the Dart side, which
                // waits before surfacing anything.
                // A stall is BUFFERING that arrives once the track is already
                // under way and the user still wants it playing. Track starts and
                // seeks buffer too, and neither says anything about the network's
                // ability to sustain this bitrate. See the note on stallCount.
                val midTrack = state == Player.STATE_BUFFERING &&
                    p.playWhenReady &&
                    p.currentPosition > 3_000L
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
                android.util.Log.i("AuvyPlayer", "isPlaying=$isPlaying")
                // Belt and braces: play/pause can arrive without a state change
                // (e.g. resuming an already-READY item).
                if (isPlaying) startPositionTicks()
                activeChannel?.invokeMethod("onIsPlayingChanged", mapOf("isPlaying" to isPlaying))
            }

            // GAPLESS: ExoPlayer auto-advanced from the current item to the
            // pre-buffered upcoming one. A mid-playlist transition does NOT fire
            // STATE_ENDED, so this is the gapless hand-off signal. Tell Dart so it
            // syncs its queue pointer + records the play + enqueues the NEXT
            // upcoming — instead of Dart re-loading the next track (the gap). Then
            // trim the just-finished item to keep the window at [current, next].
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Seek counts too, now that a skip can cause one.
                //
                // Only AUTO was forwarded, which was right while the only way to
                // change item was ExoPlayer rolling into the next one by itself.
                // advanceToUpcoming above moves deliberately, which raises
                // REASON_SEEK, and Dart would never hear about it, so its
                // currentSong and queue would silently disagree with what is
                // audible.
                //
                // Nothing else produces this: an ordinary seek stays inside one
                // item and raises no transition at all, and seekToNextMediaItem
                // is called from exactly one place.
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

        // The tick stops when there is nothing to report.
        //
        // The re-post used to sit OUTSIDE the IDLE guard, so this ran at 2Hz for
        // the whole process lifetime: the guard skipped the channel call, then
        // re-posted anyway. Twice a second, forever, while the user was only
        // browsing — the main thread never went quiescent, and because the
        // Runnable captured the ExoPlayer, the handler queue held a permanent
        // reference to the player as well.
        //
        // Now IDLE ends the loop, and any transition OUT of idle restarts it (see
        // onPlaybackStateChanged / onIsPlayingChanged). Restarting is idempotent,
        // so several triggers cannot stack up duplicate tickers.
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
            // Logged unconditionally, before any branching. Auvy was observed
            // playing over Instagram with NOT ONE focus line in the log, which left
            // "the callback never fired" and "it fired and we ignored the code"
            // indistinguishable. Now the raw code is always on the record.
            android.util.Log.i("AuvyPlayer", "audiofocus change=" + change)
            mainHandler.post {
                val p = sharedPlayer ?: return@post
                when (change) {
                    // Permanent loss (another media app grabbed full focus —
                    // Instagram, YouTube, another player). Pause; the user
                    // resumes manually. NOT during a call (keep playing).
                    android.media.AudioManager.AUDIOFOCUS_LOSS -> {
                        // Clear the flag FIRST, before any early return.
                        //
                        // A permanent loss means the system has discarded our
                        // focus request entirely — we no longer hold focus even
                        // though `hasAudioFocus` still said we did. Leaving it
                        // true made `requestAudioFocusIfNeeded()` short-circuit on
                        // the next play, so Auvy resumed holding NO focus request:
                        // the OS then had nobody to notify, and it never paused
                        // for another app again until the process restarted. That
                        // is the "sometimes it pauses, sometimes it doesn't" bug —
                        // it worked exactly once per process.
                        //
                        // Cleared even when we keep playing through a call, since
                        // the request is gone regardless of what we choose to do.
                        hasAudioFocus = false
                        if (isPhoneCallActive()) return@post
                        resumeOnFocusGain = false
                        if (p.playWhenReady) p.pause()
                        android.util.Log.i("AuvyPlayer", "audiofocus LOSS → pause (focus released)")
                    }
                    // Transient loss (nav prompt, a short clip). Pause and
                    // remember to auto-resume. NOT during a call.
                    android.media.AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                        // CALLS PAUSE THE MUSIC. The `isPhoneCallActive()` early
                        // return that used to be here was deliberate — an explicit
                        // "keep playing during a call" exception, but a phone call
                        // is EXACTLY what sends LOSS_TRANSIENT, so it made the one
                        // interruption everybody expects the only one that did
                        // nothing. Music kept playing under the caller's voice.
                        //
                        // Transient means transient: pause, remember, and resume on
                        // GAIN when the call ends, which is what the branch below
                        // already does. Nothing else about focus handling changes.
                        resumeOnFocusGain = p.playWhenReady
                        // Stamped so the GAIN branch can tell a momentary
                        // interruption from the user having moved on, and so a
                        // call, which legitimately runs long — is exempt.
                        transientLossAtMs = android.os.SystemClock.elapsedRealtime()
                        lostToCall = isPhoneCallActive()
                        if (p.playWhenReady) p.pause()
                        android.util.Log.i("AuvyPlayer", "audiofocus LOSS_TRANSIENT → pause (resume=$resumeOnFocusGain call=$lostToCall)")
                    }
                    // Duckable loss (notification beep) — lower volume, keep
                    // playing. NOT during a call.
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
                        // THROUGH normalizationVolumeScale(), NOT bare appVolume.
                        // Un-ducking to the raw value threw away the attenuation
                        // applied to a loud master, so every notification beep left
                        // the next stretch of music audibly LOUDER than before it —
                        // "the volume jumped on its own and the slider hadn't moved".
                        p.volume = appVolume * normalizationVolumeScale()
                        if (resumeOnFocusGain) {
                            resumeOnFocusGain = false
                            // A "TRANSIENT" LOSS IS NOT ALWAYS TRANSIENT, AND
                            // Resuming blind is how Auvy played over instagram.
                            //
                            // Caught in the log, and it is two separate faults:
                            //
                            //   22:25:13 GAIN → resume
                            //   22:25:17 LOSS_TRANSIENT           ← 3s burst
                            //   22:32:10 GAIN → resume            ← 7min later
                            //
                            // Instagram takes transient focus PER REEL and drops it
                            // in the gaps, so every gap was an invitation to play a
                            // few seconds over what the user was watching. And the
                            // resume intent never expired, so a loss that had lasted
                            // seven minutes still resumed — by then the user has long
                            // moved on and Auvy starting up is Auvy barging in.
                            //
                            // Two conditions, both required:
                            //
                            //  • The loss must have been SHORT. A call is exempt
                            //    because it is the one long interruption where the
                            //    user genuinely does expect the music back.
                            //  • NOBODY ELSE MAY BE AUDIBLE. We are paused here, so
                            //    isMusicActive() can only be another app — and
                            //    starting on top of it is the exact complaint.
                            if (shouldResumeOnFocusGain()) {
                                p.play()
                                android.util.Log.i("AuvyPlayer", "audiofocus GAIN → resume")
                            }
                        }
                    }
                    // The when had no else, so an unrecognised code did nothing.
                    //
                    // Silence is the worst default here: the one thing worse than
                    // pausing when we should not is playing over someone else, which
                    // is exactly what was reported. Android may deliver GAIN_TRANSIENT
                    // and GAIN_TRANSIENT_EXCLUSIVE as well as the four handled above,
                    // and any future code lands here too.
                    //
                    // A NEGATIVE code is always a loss of some kind, so treat it as a
                    // transient one: pause and remember to resume. A positive code is
                    // a gain we have no special handling for, so restore volume and
                    // resume if we had paused ourselves.
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

    // Best-effort "is a phone/VoIP call happening" — used to KEEP PLAYING
    // through call-caused focus losses (the deliberate play-during-call
    // behaviour), while still yielding to ordinary media apps. Permission-free.
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
                            // YOUTUBE track → LAZY-resolving + cached source keyed by
                            // videoId. The player is NEVER handed a
                            // fixed URL: the ResolvingDataSource resolves it per-chunk and
                            // re-resolves via Dart on expiry/403/IP-change, with the
                            // media3 play-cache serving already-streamed bytes. Seed the
                            // URL cache with what Dart already resolved so the first play
                            // needs no extra round-trip.
                            // freshStart: this is the ORDINARY streaming start, so it
                            // REPLACES the mid-track format pin (see seedUrl — the pin
                            // being open-coded is what left this path unpinned, and
                            // therefore left the pin inert everywhere that mattered).
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
                        // A DOWNLOADED next track. Previously absent, and that was
                        // the biggest hole in gapless: Dart only armed an upcoming
                        // item for tracks it had to resolve a URL for, so playing a
                        // downloaded album — the case where seamlessness is most
                        // expected, and easiest, since the bytes are already on
                        // disk — took the reload path and had an audible seam.
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
                                    // THE PIN WAS MISSING HERE. This is the FOURTH
                                    // seed site, and it was the one still open-coded
                                    // after the last pass hooked the other three — so
                                    // a track that reached the player as the gapless
                                    // upcoming (the common case whenever gapless is on)
                                    // played with expectContentLength=0, and a mid-track
                                    // re-resolve of it was free to switch format.
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
                        // The skip that does NOT re-prepare
                        //
                        // A natural track end is instant: ExoPlayer rolls into
                        // the item setUpcoming pre-buffered. A MANUAL skip threw
                        // that away — Dart re-resolved the stream and prepared
                        // the track from scratch, so the same next song that
                        // would have started with zero gap instead waited on a
                        // network round trip. That is the reported "skip has a
                        // delay but it works".
                        //
                        // The id is matched HERE rather than in Dart because
                        // this is where the truth lives: Dart keeps no record of
                        // what is armed, and between its check and its call the
                        // queue can be reordered. Refusing on a mismatch lets the
                        // caller fall back to the ordinary path, so the worst
                        // case is exactly the behaviour we have today.
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
                    "clearUrlCache" -> {
                        // Every cached googlevideo URL is bound to the egress IP it
                        // was resolved from, so after a WiFi<->mobile switch they
                        // ALL 403. Drop them so the next chunk fetch re-resolves a
                        // FRESH url on the new network instead of retrying the dead
                        // one (the "switched network → acts offline / stuck" bug).
                        // The Dart resolver's invalidateAllStreams only cleared the
                        // Dart cache; since the native refactor the URLs that drive
                        // playback live HERE, so that was a no-op for playback.
                        songUrlCache.clear()
                        currentResolveKey = null
                        android.util.Log.i("AuvyPlayer", "clearUrlCache — dropped all cached stream URLs (network change)")
                        result.success(null)
                    }
                    "promoteFromPlayCache" -> {
                        // "Save-from-stream" (cache what you actually played):
                        // if the WHOLE track is already sitting in the media3 play-cache
                        // (you streamed it end-to-end), copy those exact bytes into a
                        // file for the visible Cached/Downloads folder — ZERO network,
                        // instead of the old Dart HTTP re-download (the mobile-data
                        // drain). Returns {promoted:true,bytes} only when the full track
                        // is cached from byte 0; else {promoted:false,reason} so Dart can
                        // fall back to an HTTP download (explicit downloads) or skip it.
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

                                    // A short copy is NOT a promotion
                                    //
                                    // This reported promoted:true with whatever `written`
                                    // happened to be, having verified only that the cache
                                    // HELD the whole track before starting. The copy itself
                                    // was never checked.
                                    //
                                    // Two failures follow from that, and the second is the
                                    // dangerous one:
                                    //
                                    //  • ZERO bytes reads as success. Dart has a guard for
                                    //    that (it deletes the file and downloads properly),
                                    //    which is why it was survivable.
                                    //  • A PARTIAL copy — 2 MB of a 4 MB track — reads as
                                    //    success too, and Dart's guard cannot catch it,
                                    //    because its test is `bytes > 0`. A truncated file
                                    //    gets registered as a complete cached track, and
                                    //    every later play of it stops early with nothing to
                                    //    explain why.
                                    //
                                    // The expected length is already known here, so the
                                    // check is exact. A short file is deleted rather than
                                    // left for a later disk scan to import as real.
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
                    // User-initiated pause/stop: no transition is pending — drop
                    // any bridge locks so nothing is held while idle.
                    // An explicit pause cancels any pending auto-resume.
                    //
                    // Without this, the sequence that annoyed the user could not be
                    // stopped by hand: another app takes transient focus, Auvy pauses
                    // and arms `resumeOnFocusGain`, the user opens Auvy and presses
                    // pause, and Auvy still restarted itself the moment focus came
                    // back, because the flag survived the one action that means
                    // "stay stopped".
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
                                    // SCO is the telephony leg of a headset —
                                    // 8/16 kHz mono. The EARPIECE is the one you
                                    // hold to your head during a call. Neither is
                                    // ever a music output, and the earpiece is
                                    // what listed a second "SM-S926B" row beside
                                    // the speaker: Samsung reports the phone's
                                    // MODEL as the product name of every built-in
                                    // device, so it looked like another speaker.
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
                                    // A dock or an automotive bus IS a car, with no
                                    // permission needed to know it. A car stereo on
                                    // plain Bluetooth cannot be told apart from
                                    // headphones without BLUETOOTH_CONNECT, which
                                    // Auvy does not ask for, so such a car appears
                                    // as an ordinary Bluetooth device under its own
                                    // name rather than being guessed at.
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
                    // Points THIS PLAYER at one output. id < 0 clears the
                    // preference and hands routing back to the system.
                    //
                    // THIS MOVES AUVY'S AUDIO, NOT THE DEVICE'S. Android gives
                    // no app the power to re-route other apps, and that is the
                    // right behaviour for a picker inside a player: choosing
                    // headphones here must not yank a call or a video out of
                    // whatever it was using. Anything needing a device-wide
                    // change — pairing, Cast — still belongs to the system
                    // dialog, which the sheet also offers.
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
                        // ExoPlayer's built-in silence trimmer. The Settings toggle
                        // used to only flip a Dart bool and persist it — it never
                        // reached the engine, so "Skip silence" did nothing at all.
                        // media3 already ships SilenceSkippingAudioProcessor in the
                        // default audio sink; this is the switch that arms it.
                        player.skipSilenceEnabled = call.argument<Boolean>("enabled") ?: false
                        result.success(null)
                    }
                    // Throughput + stalls since the last read, for the Dart-side
                    // bitrate ladder. READ-AND-CLEAR on the stall count: the ladder
                    // asks "has anything gone wrong SINCE I last decided?", and a
                    // running total would keep re-triggering the same downgrade
                    // long after the network recovered.
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
                        // The attenuation half only ever landed one track late.
                        //
                        // applyNormalization handles the BOOST (LoudnessEnhancer);
                        // a negative gain is applied as a player-volume trim, and
                        // that trim used to be recomputed only inside "setVolume".
                        // Dart calls setVolume BEFORE this, so setVolume scaled by
                        // the PREVIOUS track's gain and the new gain then sat unused
                        // until the next track called setVolume, which scaled by
                        // this one. Every track got its neighbour's correction.
                        //
                        // Audibly: one loud master pulled the volume down (to as
                        // little as 0.1) and it STAYED down over the quiet tracks
                        // that followed, which is the "everything sounds dampened,
                        // then suddenly jumps" report. Recomputing here makes the
                        // gain and the trim change together, in either call order.
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
                    // Is ANY app currently producing music on this device?
                    //
                    // This exists to defend against MISROUTED media buttons. A
                    // multipoint Bluetooth headset paired to both a phone and a PC
                    // sends its AVRCP PLAY over BOTH links: press play on the PC and
                    // the phone receives PLAY too. Android hands that to whichever
                    // app owns the most recent media session — Auvy, which then
                    // starts playing music nobody asked for, on a device the user
                    // isn't even listening to. Android 11+ media resumption makes it
                    // worse by RESTARTING the app's service to deliver it, so Auvy
                    // appears to launch itself out of nowhere.
                    //
                    // `AudioManager.isMusicActive()` is device-wide and
                    // permission-free: if music is already playing and it isn't us,
                    // the PLAY was not meant for us.
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
     * [mediaId] MATTERS — it is not decoration. onMediaItemTransition reports
     * `mediaItem.mediaId` to Dart as the id that just started playing, and Dart
     * matches that against its queue to recognise a gapless advance. This used
     * MediaItem.fromUri, which leaves the id at its empty default, so a local
     * track queued as the gapless upcoming would announce itself with no id and
     * Dart would fail to match it. Always pass the videoId.
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

    /// Seed [songUrlCache] for [videoId] and record the format pin, in ONE place.
    ///
    /// THERE ARE FOUR SEED SITES AND THEY MUST AGREE. playTrack, setUpcoming,
    /// prewarmNext and the lazy resolve all put a url in the cache, and each one
    /// also has to record `inUseContentLength` (the mid-track format pin) and check
    /// the play-cache for another format's bytes. That was open-coded, and the pin
    /// therefore landed at one site out of four — inert on the ordinary streaming
    /// path, which is why it looked fixed for two commits while never once engaging.
    /// A shared function is the only version of this that stays true when a fifth
    /// site appears.
    ///
    /// [freshStart] — a track (re)starting, which REPLACES the pin, and CLEARS it
    /// when no length is known so a stale pin cannot outlive the format it
    /// described and begin refusing legitimate resolves. False for a lazy mid-track
    /// resolve, which must never overwrite an existing pin: doing so would let a
    /// format that slipped through become the new expectation, which is precisely
    /// what the pin exists to prevent.
    ///
    /// Returns the entry actually stored.
    private fun seedUrl(
        videoId: String,
        url: String,
        userAgent: String,
        contentLength: Long,
        freshStart: Boolean,
    ): UrlEntry {
        // Recover the length from the URL when Dart does NOT supply one.
        //
        // ANDROID audio formats routinely omit contentLength in the player JSON, so
        // it arrives here as 0 — buildSource already had to work around exactly this
        // for its Range bounding. A 0 makes BOTH format defences blind: the pin is
        // cleared (so a mid-track re-resolve is free to switch format) and the
        // mismatch check returns early (so another format's bytes stay on disk).
        // googlevideo states the true length in the url's own &clen=, which is the
        // same number Dart would have sent.
        val clen = if (contentLength > 0L) contentLength
            else Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.getOrNull(1)?.toLongOrNull() ?: 0L
        // A track (re)starting is the only safe moment to notice that the bytes on
        // disk belong to another format, and it must run BEFORE the pin below is
        // overwritten, since the old pin is one of the two witnesses.
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
        // NEVER EVICT THE TRACK THAT IS STREAMING. Eviction order is by expiry,
        // and the playing track's url has no special place in that order, so a full
        // cache could drop the very entry the loader is about to ask for. That alone
        // is survivable (it re-resolves), but it also makes the track's PIN eligible
        // for the sweep below on a later call, and losing the pin mid-track is what
        // lets the format switch that all of this exists to prevent.
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
            // THIS ONE CANNOT BE PRUNED BY EXPIRY, and must not simply follow
            // songUrlCache: the 403 path deliberately removes the url entry while
            // keeping the pin, because the pin is exactly what tells Dart which
            // format to hand back. Dropping a pin for the track being recovered
            // would reintroduce the mid-track format switch.
            //
            // So drop only pins that no longer back a live url AND are not the key
            // currently resolving. songUrlCache is capped far lower, so there are
            // always plenty of those and this is guaranteed to shrink.
            inUseContentLength.entries.removeIf {
                it.key != keep && !songUrlCache.containsKey(it.key)
            }
        }
    }

    /// Drop the play-cache for [videoId] when what is on disk belongs to a
    /// DIFFERENT audio format than the one about to play.
    ///
    /// This is the always-the-same-timestamp stall, AND it was never the URL.
    ///
    /// buildResolvingSource sets customCacheKey = videoId and the prewarm keys its
    /// DataSpec the same way, so EVERY format of a track shares ONE cache
    /// namespace. itag 140 and itag 251 are different files, of different lengths,
    /// with different byte layouts, and their bytes land at overlapping offsets
    /// under the same key. Which format a track resolves to varies with the quality
    /// setting, with shouldUseLowQualityAudio flipping on a network change, and with
    /// the stream-client rotation, so one song accumulates spans from both.
    ///
    /// CacheDataSource then computes its request from those mixed spans. Captured
    /// live, on one track, across consecutive retries:
    ///
    ///   pos=1048576 len=446989 itag=140 clen=3406710
    ///   pos=1048576 len=446989 itag=251 clen=3594577
    ///
    /// `len` is not the 512 KB chunk cap — it is a HOLE: 1048576 + 446989 =
    /// 1495565, the exact gap between where the prewarm stopped and where the
    /// OTHER format's bytes resume. Identical under both itags, because the
    /// geometry comes from the cache, which does not know formats apart. So the
    /// player asks a url for a range derived from a different file, and googlevideo
    /// refuses it — every time, at the same offset, no matter how fresh the url is.
    /// That is why re-resolving could not help and why pinning the format could not
    /// either: the pin stops the format from changing mid-track, but the wrong-format
    /// bytes were already on disk from an EARLIER play.
    ///
    /// Mixed spans are also silent corruption in their own right — where they do not
    /// 403 they splice two encodings into one stream.
    /// RECORDS ITS OWN WITNESS RATHER THAN READING media3's.
    ///
    /// The obvious witness is the cache's own KEY_CONTENT_LENGTH, and it is not
    /// trustworthy here: the prewarm writes a BOUNDED 1 MB request, and if media3
    /// records the length it was asked for rather than the length of the resource,
    /// then every single track would look like a format change one moment after
    /// being prewarmed — silently throwing away the prewarm on every transition and
    /// making the feature look broken rather than the bug fixed. Depending on that
    /// behaviour is not worth it when one line records something exact.
    ///
    /// So Auvy stores the format length under its own metadata key, which also means
    /// the witness SURVIVES A RESTART — the case that matters most, since the
    /// wrong-format bytes usually come from an earlier session.
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
            // Ask for the same format, NOT just a fresh URL.
            //
            // This sent only the videoId, so Dart was free to pick any format —
            // and its client rotation escalates on resolves repeating within 20s,
            // which is precisely what a mid-track 403 storm looks like. So the
            // recovery was GUARANTEED to switch format mid-file.
            //
            // Captured on one track across consecutive attempts:
            //   itag=140 clen=3406710
            //   itag=251 clen=2708020
            //
            // A different itag is a different FILE with a different length and
            // byte layout. The player had already consumed 1 MiB of the first one
            // and then asked the second for bytes=1048576+ — a range that means
            // nothing in that file, so it 403s, so it re-resolves, so it rotates
            // again. The recovery mechanism was the reason the loop never
            // recovered.
            //
            // expectContentLength is how Dart knows this is a mid-track
            // re-resolve and must NOT rotate.
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
        // The url just resolved IS now the one in use, so it defines the format any
        // later re-resolve for this track has to match — recorded only when absent
        // (freshStart = false), because this is a mid-track resolve and overwriting
        // would let a format that slipped through become the new expectation.
        //
        // Returns the STORED entry, not `resolved`: priming marks the instance that
        // lives in the cache, and handing back a detached copy would lose the flag
        // and re-prime the same url on every chunk.
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
                // UNCONDITIONAL, AND FIRST. EVERY OTHER PROBE HERE HAS A GUARD
                // That turned out to exclude the case it was built for.
                //
                // The full "403 DETAIL" dump below only runs at `errorCount == 1`,
                // and a live storm never produces a single line for that iteration
                // — the logs jump straight to "try 2". So the one diagnostic meant
                // to identify this bug has been silent through every occurrence of
                // it, which is why two contradictory explanations (a missing
                // proof-of-origin token vs a CacheDataSource hole) have both
                // survived. A probe that can be skipped is not a probe.
                //
                // Nothing is derived here and nothing can return before it. Values
                // are URL query parameters and byte offsets — no titles, no
                // queries, no identity, so it is safe in a release build.
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
                // Is the URL we are holding actually STALE?
                // This branch used to assume "403 ⇒ stale URL" and drop the cached
                // entry immediately, on every single 403. Live capture of the
                // always-same-timestamp stall shows that assumption is wrong:
                //
                //   403 DETAIL pos=1048576 ... expire=1785821071 now=1785799471
                //
                // expire − now = 21600s — the URL had SIX HOURS of validity left.
                // It was discarded anyway, so all 12 following retries ran against
                // brand-new URLs and every one of them 403'd at the same offset.
                //
                // pos=1048576 is exactly PREWARM_BYTES, i.e. the first byte
                // playback has to fetch for itself (everything below it was served
                // from the prewarm's cache). So the failing request is the first
                // MID-FILE range request of the track, and googlevideo does reject
                // a range that starts mid-file on a URL that has never served the
                // bytes before it. The prewarm primed URL_A by reading it from 0;
                // dropping the cache handed each retry a virgin URL_B, URL_C … and
                // asked it to start at 1 MB, which is precisely the shape that
                // fails. The recovery was manufacturing the condition it was
                // trying to recover from.
                //
                // So: hold onto a URL that is still valid and retry the SAME one
                // first. Only escalate to a re-resolve once same-URL retries have
                // genuinely failed, or when the URL really has expired, which is
                // the case this branch was written for and still handles.
                val key = currentResolveKey
                val cached = key?.let { songUrlCache[it] }
                val urlStillValid =
                    cached != null && cached.expiresAtMs > System.currentTimeMillis() + 10_000L
                val escalateToFreshUrl =
                    !urlStillValid || info.errorCount > SAME_URL_403_RETRIES
                if (escalateToFreshUrl) key?.let { songUrlCache.remove(it) }
                // BOUNDED. This branch used to return 500L unconditionally,
                // which bypassed getMinimumLoadableRetryCount entirely and made
                // 403s retry FOREVER at 2/second. Normally invisible — a stale
                // URL re-resolves on the first or second try, but if the fresh
                // URL 403s too (a client whose streams are gated for this track,
                // now reachable from Settings → Stream sources by leaving only a
                // weak client on) it became an endless resolve storm with no
                // error ever surfaced. Observed live: "try 16" and climbing.
                //
                // Past the cap, fall through to super, which ends retries and
                // hands over to Dart's error recovery. The generous count is
                // unchanged, so Doze/CDN-gate recovery behaves exactly as before.
                // DIAGNOSTIC for the "always stops at the same timestamp" bug.
                //
                // Re-resolving 13 times does not help, which means the URL is NOT
                // what is being rejected — the RANGE is. This logs, once per 403,
                // everything needed to tell the candidate causes apart:
                //   • pos/len   → the exact byte offset it dies at (does it really
                //                 line up with the playback position that fails?)
                //   • range=    → if the URL carries its OWN range bound, asking
                //                 past it 403s forever no matter how fresh it is
                //   • pot/n     → a missing proof-of-origin token lets the first
                //                 burst through and 403s the rest
                //   • expire vs now → already covered by urlExpired(), confirms it
                //   • itag/clen → which format, and what length it claims
                // Logged at W via android.util.Log so it SURVIVES release builds.
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
                            // WHY THE CACHE STATE: `len` came back as 446622 on one
                            // song and 446630 on another — under a 524288 chunk cap,
                            // and IDENTICAL across two different itags of the same
                            // song, so it tracks neither the chunk size nor clen.
                            // 1048576 + 446622 = 1495198, which is the shape of a
                            // CacheDataSource HOLE: it asks for exactly the gap
                            // between where the prewarm stopped and the next region
                            // already on disk. If that is what this is, the span
                            // dump below shows the region above the hole; if the
                            // cache is empty past 1 MB then `len` comes from
                            // somewhere else and the hole theory is dead.
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
                            // The CDN usually states the reason in a header.
                            // GUARDED: headerFields is NULLABLE on this exception
                            // (it was null on every capture so far) and the
                            // unguarded forEach NPE'd, which is exactly why the
                            // response headers — the part that would NAME the
                            // refusal — were missing from all six samples.
                            // Iterate entries, do NOT destructure.
                            //
                            // `headers.forEach { (hk, hv) -> … }` compiles to
                            // component1()/component2() on each Map.Entry, and
                            // HttpURLConnection's header map contains an entry with
                            // a NULL KEY — the HTTP status line. component1() is
                            // declared non-null, so that entry threw
                            // "component1(...) must not be null" before the null
                            // check inside the body could ever run.
                            //
                            // That is why every single capture logged
                            // "403 DETAIL unavailable: NullPointerException" and the
                            // response headers — the one part that would NAME the
                            // refusal — were missing from all of them. The guard was
                            // there; it was just unreachable.
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
                    // Back off when fresh URLs keep failing
                    //
                    // A new URL cannot help while the network path is moving.
                    //
                    // This returned a flat 500ms for every 403, so once same-URL
                    // retries were spent it re-resolved twice a second. Captured
                    // live during a Samsung Wi-Fi flap (SemWifiOptimizer toggling
                    // between a dual-stack Wi-Fi and an IPv6-only LTE path):
                    //
                    //   try 5  re-resolving → stream OK → 403
                    //   try 6  re-resolving → stream OK → 403
                    //   try 7  re-resolving → stream OK → 403
                    //   try 8  re-resolving → stream OK → 403
                    //
                    // Four full resolves in four seconds, every one of them
                    // arriving already-dead because googlevideo pins a URL to the
                    // egress IP that fetched it, and the IP was still moving.
                    // That is wasted data and wasted battery, and it fills the
                    // retry budget so fast that the track has no chance to start.
                    //
                    // A repeated FRESH-url failure therefore means the path is the
                    // problem, not the URL, and the only useful response is to wait
                    // a moment. The first escalation stays fast, because a genuinely
                    // expired URL is the common case and re-resolves immediately;
                    // each further one doubles, to 5s.
                    //
                    // errorCount resets when a load finally succeeds, so this needs
                    // no state of its own.
                    val escalations =
                        (info.errorCount - SAME_URL_403_RETRIES).coerceAtLeast(0)
                    // Bound the escalations, NOT just the delay.
                    //
                    // Doubling with a 5s ceiling looked harmless and was not: across
                    // the 12-retry budget it turned a SIX-second give-up into
                    // THIRTY-FOUR, so a genuinely gated track left the user in
                    // silence for half a minute before Dart skipped on. Capping the
                    // delay at 2.5s still gave 20s.
                    //
                    // A path flap settles in a few seconds, so backoff past a few
                    // escalations buys nothing — it only delays the graceful skip.
                    // Three escalations (0.5s + 1s + 2s on top of the same-url
                    // retries) totals ~5.5s: slightly FASTER to give up than the
                    // original flat 500ms ladder, while making three resolve
                    // attempts instead of eight.
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
                //"GIVING UP" DID NOT GIVE UP.
                //
                // This returned super.getRetryDelayMsFor(info), and the comment
                // claimed that "ends retries". It does not: the default policy
                // returns a DELAY, so the loader simply waited and tried again.
                // Captured live — the counter kept climbing long past the cap:
                //
                //   403/410 persisted past 13 tries — giving up, letting Dart heal
                //   403/410 persisted past 14 tries — giving up, letting Dart heal
                //   …
                //   403/410 persisted past 22 tries — giving up, letting Dart heal
                //
                // Twenty-two attempts, each one logging that it was giving up. The
                // signal for "fatal, do not retry" is C.TIME_UNSET; anything else
                // is a request to try again. This is what lets Dart heal PROMPTLY
                // instead of after a minute of invisible thrashing.
                android.util.Log.w("AuvyPlayer", "403/410 persisted past ${info.errorCount} tries — FATAL, letting Dart heal")
                return C.TIME_UNSET
            }
            // Connectivity fault (radio asleep under Doze): the URL is fine — keep
            // retrying the SAME range, waiting for the radio to wake.
            if (ChunkedDataSource.isConnectivityError(cause)) {
                android.util.Log.w("AuvyPlayer", "network outage on chunk — waiting for radio (try ${info.errorCount})")
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
                            ),
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
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(15000)
            .setDefaultRequestProperties(mapOf("Connection" to "keep-alive"))

        // CRITICAL: googlevideo returns HTTP 403 for open-ended Range requests
        // (bytes=N-), which is exactly what ExoPlayer sends by default. Bounding
        // every request to the known content length makes the Range bytes=N-END,
        // which the CDN serves (206). This is THE fix for the audio not playing.
        //
        // Dart usually supplies the length, but ANDROID audio formats often omit
        // `contentLength` in the player JSON (it arrives here as 0). In that case
        // recover it from the URL's own `&clen=` query param — otherwise we'd fall
        // back to an unbounded request and 403 in an endless self-heal loop.
        val clen = if (contentLength > 0) contentLength
            else Regex("[?&]clen=(\\d+)").find(url)?.groupValues?.getOrNull(1)?.toLongOrNull() ?: 0L

        android.util.Log.i("AuvyPlayer", "buildSource arg=$contentLength clen=$clen chunked=${clen > 0} host=${Uri.parse(url).host}")

        val uri = Uri.parse(url)

        // Live HLS radio (.m3u8): progressive playback can't parse a playlist, so
        // these stations failed. Route them through HlsMediaSource. (Direct
        // icecast/MP3/AAC streams keep working via the progressive path below.)
        if (clen <= 0L && url.contains(".m3u8", ignoreCase = true)) {
            android.util.Log.i("AuvyPlayer", "buildSource HLS live stream host=${uri.host}")
            return HlsMediaSource.Factory(httpFactory).createMediaSource(MediaItem.fromUri(uri))
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

        return ProgressiveMediaSource.Factory(factory)
            .setLoadErrorHandlingPolicy(failFastOn403)
            .createMediaSource(MediaItem.fromUri(uri))
    }
}
