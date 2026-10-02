package com.auvy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.File

/**
 * Captures audio for song recognition, either what another app is playing
 * (screen-audio capture) or what the microphone hears.
 *
 * ## Modes
 *
 * **One-shot** ([ACTION_ONESHOT]): the in-app long-press. Acquires a
 * MediaProjection, records, hands the PCM back through [onResult], stops.
 *
 * **Mic** ([ACTION_MIC]): the quick-settings tile (via TileCaptureActivity).
 * Records from the microphone, which hears the phone's own speaker, so it
 * needs no consent dialog.
 *
 * ## Where identification happens
 * Recognition is Dart code. A tile capture writes the raw PCM to a file and
 * records a marker pref, then asks a running Flutter engine to identify it,
 * or starts a headless engine if none answers (see runHeadlessRecognition).
 */
class AudioCaptureService : Service() {

    companion object {
        private const val TAG = "AuvyCapture"
        private const val CHANNEL_ID = "auvy_capture"
        private const val NOTIF_ID = 8801

        /// The one id the whole recognition flow lives on — progress and answer
        /// alike, from either path. Exposed so MainActivity's in-app result
        /// replaces the "Identifying…" line instead of appearing beside it.
        const val RESULT_NOTIF_ID = NOTIF_ID

        /// How long the headless engine gets before we give up on it. Generous
        /// enough for a cold Dart boot plus a network lookup on mobile data, short
        /// enough that a wedged run does not pin the process.
        private const val HEADLESS_TIMEOUT_MS = 25_000L

        /// How long to wait for the isolate to report that it is ALIVE, as
        /// opposed to finished. See the boot watchdog in runHeadlessRecognition.
        private const val HEADLESS_BOOT_TIMEOUT_MS = 10_000L

        /// Sentinel for "Dart has reported nothing at all".
        private const val PHASE_NONE = "not started"

        /// Grace period before retiring a process that hosted a headless engine.
        /// Long enough for the result notification to post and for a fast tap on
        /// it to bring MainActivity up (which cancels the retirement), short
        /// enough that a later tap gets a clean process.
        private const val PROCESS_RETIRE_DELAY_MS = 3_000L

        const val ACTION_ONESHOT = "com.auvy.app.CAPTURE_ONESHOT"
        /** Record from the MICROPHONE — the tile's path. No projection needed. */
        const val ACTION_MIC = "com.auvy.app.CAPTURE_MIC"

        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_SECONDS = "seconds"

        /** 16-bit mono at this rate — what the Shazam signature path expects. */
        const val SAMPLE_RATE = 44100

        /** Temp PCM file a tile capture leaves for Dart to pick up. */
        const val PENDING_FILE = "auvy_pending_capture.pcm"

        /**
         * Flutter-side pref key holding the pending capture's path. Written with the
         * `flutter.` prefix because that's the namespace shared_preferences uses —
         * the same cross-language trick AlarmScheduler relies on.
         */
        private const val PREF_PENDING = "flutter.auvy_pending_capture"

        /** The MediaProjection held while a one-shot capture records. */
        @Volatile
        private var armedProjection: MediaProjection? = null

        /// How long the live engine gets to acknowledge a handoff before the headless
        /// path takes over. Short on purpose: Dart only has to accept the work, and
        /// every extra second is silence on the notification.
        private const val HANDOFF_TIMEOUT_MS = 1500L

        /// Asks Dart to identify a capture that has just been written, reporting
        /// through [ack] whether Dart actually took the work.
        ///
        /// A non-null listener doesn't prove a live engine: MainActivity sets it and
        /// nothing clears it, so it outlives the activity. Clearing it on destroy
        /// wouldn't work either, because audio_service can keep the engine alive. So
        /// the service asks, and falls back to the headless engine only if no answer
        /// arrives within HANDOFF_TIMEOUT_MS.
        @Volatile
        var onCaptureReady: ((ack: (Boolean) -> Unit) -> Unit)? = null

        /**
         * True while a capture is running, so the tile can't stack them.
         *
         * onStartCommand sets it on the same thread that checks it (before starting
         * the worker), so two quick taps can't both pass the check. micToFile
         * clears it in a finally so no exit path leaves the tile stuck "busy".
         */
        @Volatile
        var isCapturing = false
            private set

        /** One-shot result delivery (in-process; both live in the same process). */
        @Volatile
        var onResult: ((ByteArray?) -> Unit)? = null
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    /// The headless Dart engine, alive only while identifying a tile capture with
    /// the app closed. Non-null means one is running. See runHeadlessRecognition.
    private var headlessEngine: io.flutter.embedding.engine.FlutterEngine? = null

    /// True from the moment headless recognition is scheduled until it finishes.
    /// Separate from [headlessEngine] because the engine is created on a POSTED
    /// runnable, so there is a window where work is pending and the engine is still
    /// null, and stopping the service in that window kills the identification.
    @Volatile
    private var headlessPending = false

    /// Last step the headless isolate reported reaching. Named in the timeout log
    /// so a stall says WHERE it stalled. See the "phase" branch below.
    @Volatile
    private var lastHeadlessPhase = "not started"

    /// True once the final answer has been posted onto the service's own
    /// notification. Decides whether teardown may take that notification with it —
    /// see onDestroy.
    @Volatile
    private var resultShowing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_ONESHOT
        // Go foreground first: from API 34 MediaProjection is refused unless a
        // mediaProjection-typed foreground service is already running.
        //
        // The service type must match the source (microphone vs mediaProjection) on
        // API 34+, so it's chosen from the action; the manifest declares both.
        //
        // Starting a microphone foreground service without RECORD_AUDIO throws
        // SecurityException and crashes the app, so the permission is checked here
        // too, not only by the tile.
        if (action == ACTION_MIC &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
            != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "mic capture refused — RECORD_AUDIO not granted")
            notifyResult("Microphone needed", "Open Auvy once to allow the microphone.")
            stopSelf()
            return START_NOT_STICKY
        }

        val notif = buildNotification(listening = action == ACTION_MIC)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = if (action == ACTION_MIC) {
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                startForeground(NOTIF_ID, notif, type)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (e: Exception) {
            // Belt and braces behind the guard above: whatever else the platform
            // decides to refuse here, a refusal must degrade to "no capture", never
            // to a crash. There is nothing worth taking the app down for.
            Log.w(TAG, "startForeground refused: ${e.javaClass.simpleName} ${e.message}")
            try {
                notifyResult("Could not listen", "Android refused the microphone just now.")
            } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }

        when (action) {
            // Mic capture (used by the tile): no MediaProjection, no consent dialog.
            // Needs RECORD_AUDIO granted and FOREGROUND_SERVICE_MICROPHONE declared
            // (without the latter, API 34+ throws SecurityException).
            ACTION_MIC -> {
                if (isCapturing) {
                    Log.w(TAG, "mic capture ignored — already capturing")
                } else {
                    val seconds = intent?.getDoubleExtra(EXTRA_SECONDS, 8.0) ?: 8.0
                    isCapturing = true
                    Thread { micToFile(seconds) }.start()
                }
            }
            else -> {
                val code = intent!!.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                val seconds = intent.getDoubleExtra(EXTRA_SECONDS, 8.0)
                if (data == null || !acquireProjection(code, data)) {
                    finishOneShot(null)
                } else {
                    val p = armedProjection
                    Thread {
                        val bytes = if (p == null) null else record(p, seconds)
                        // One-shot owns its projection, so release it again.
                        releaseProjection()
                        finishOneShot(bytes)
                    }.start()
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun acquireProjection(resultCode: Int, data: Intent): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                    as MediaProjectionManager
            val p = mgr.getMediaProjection(resultCode, data) ?: return false
            // Required since API 34, and it's also the only signal if the user
            // revokes capture from the status bar.
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "projection stopped externally")
                    armedProjection = null
                }
            }, mainHandler)
            armedProjection = p
            true
        } catch (e: Exception) {
            Log.w(TAG, "acquire failed: ${e.message}")
            false
        }
    }

    private fun releaseProjection() {
        try { armedProjection?.stop() } catch (_: Exception) {}
        armedProjection = null
    }

    /**
     * Mic capture: record, write the PCM to the pending file, notify, and hand it
     * to Dart (onCaptureReady, or the headless engine if nothing answers).
     */
    private fun micToFile(seconds: Double) {
        try {
            val bytes = micRecord(seconds)
            if (bytes == null || bytes.isEmpty()) {
                notifyResult("Nothing heard", "Turn the volume up and try again.")
                return
            }
            val f = File(cacheDir, PENDING_FILE)
            f.writeBytes(bytes)
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit().putString(PREF_PENDING, f.absolutePath).apply()
            Log.i(TAG, "mic capture written: ${bytes.size} bytes")

            // "Identifying…" is posted, then the capture is handed to the running
            // engine; if no engine acknowledges in time, the headless engine is started
            // instead, so the notification never sits on "Identifying…" forever.
            notifyResult("Identifying…", "Matching what was playing.",
                terminal = false)
            val listener = onCaptureReady
            if (listener != null) {
                // Ask the engine, but only trust it if it ANSWERS. A stale listener
                // silently swallowing the handoff is what left captures unidentified.
                headlessPending = true
                val answered = java.util.concurrent.atomic.AtomicBoolean(false)
                val fallback = Runnable {
                    if (answered.compareAndSet(false, true)) {
                        Log.w(TAG, "engine did not answer the handoff - going headless")
                        runHeadlessRecognition()
                    }
                }
                mainHandler.postDelayed(fallback, HANDOFF_TIMEOUT_MS)
                try {
                    listener.invoke { ok ->
                        if (answered.compareAndSet(false, true)) {
                            mainHandler.removeCallbacks(fallback)
                            if (ok) {
                                Log.i(TAG, "handoff accepted by the live engine")
                                headlessPending = false
                            } else {
                                Log.w(TAG, "engine refused the handoff - going headless")
                                runHeadlessRecognition()
                            }
                        }
                    }
                } catch (t: Exception) {
                    Log.w(TAG, "handoff threw: " + t.message)
                    mainHandler.post(fallback)
                }
            } else {
                // Auvy is closed. Start a HEADLESS engine and identify anyway,
                // rather than telling the user to go and open the app.
                Log.i(TAG, "no engine — starting headless recognition")
                // Claimed BEFORE the post, not inside runHeadlessRecognition: the
                // `finally` below runs before a posted Runnable does, so a flag set
                // in there would still read false and the service would stop out
                // from under the engine.
                headlessPending = true
                mainHandler.post { runHeadlessRecognition() }
            }
        } catch (e: SecurityException) {
            // Almost always RECORD_AUDIO not granted. Named explicitly because the
            // last time this threw, the cause was misdiagnosed as a platform rule.
            Log.w(TAG, "mic capture denied: ${e.message}")
            notifyResult("Microphone needed", "Open Auvy and allow the microphone.")
        } catch (e: Exception) {
            Log.w(TAG, "mic capture failed: ${e.javaClass.simpleName} ${e.message}")
            notifyResult("Capture failed", "Could not listen just now.")
        } finally {
            isCapturing = false
            // Switch the tile back off. Cleared BEFORE asking, so the refresh reads
            // the finished state rather than racing this line and latching "on".
            RecognizeTileService.requestRefresh(this)
            // Don't stop while a headless recognition is pending: the foreground
            // service is what keeps the process alive while it runs. tearDownHeadless
            // stops the service when the engine reports or times out.
            if (!headlessPending) stopSelf()
        }
    }

    /**
     * Run the Dart recogniser with no Activity, so a tile capture is identified
     * even with Auvy closed.
     *
     * What a hand-built engine needs:
     *
     * • FlutterLoader initialised before the engine is constructed, or the Dart
     *   snapshot can't be found (idempotent, so safe to call every time).
     * • Plugins registered by hand; see registerHeadlessPlugins for which.
     * • The entrypoint needs `@pragma('vm:entry-point')` so release
     *   tree-shaking keeps it, and it must be looked up with its library URI.
     *
     * Torn down on the result or on a timeout, so the engine doesn't keep the
     * process alive.
     */
    private fun runHeadlessRecognition() {
        if (headlessEngine != null) {
            Log.i(TAG, "headless recognition already running")
            return
        }
        try {
            val loader = io.flutter.FlutterInjector.instance().flutterLoader()
            if (!loader.initialized()) loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)

            val engine = io.flutter.embedding.engine.FlutterEngine(applicationContext)
            headlessEngine = engine
            registerHeadlessPlugins(engine)

            val channel = io.flutter.plugin.common.MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.auvy.app/headless_recognition",
            )
            channel.setMethodCallHandler { call, result ->
                if (call.method == "phase") {
                    // Progress from the headless isolate, the only visibility into this path in
                    // a release build (Dart print() is stripped). The timeout log names the last
                    // phase reached. Phase names are fixed constants (`captured`, `matched`…),
                    // never a title, artist, query or path.
                    lastHeadlessPhase = call.argument<String>("name") ?: "?"
                    Log.i(TAG, "headless phase: $lastHeadlessPhase")
                    result.success(null)
                } else if (call.method == "result") {
                    val title = call.argument<String>("title") ?: "No match"
                    val text = call.argument<String>("text") ?: ""
                    val found = call.argument<Boolean>("found") ?: false
                    // On failure, log which failure (the title is one of the app's own fixed
                    // strings). A match logs only the flag: the song title is user content and
                    // doesn't belong in logcat.
                    Log.i(TAG, "headless recognition finished (found=$found" +
                        (if (!found) " — $title" else "") + ")")
                    // Same notification either way: on a match the title IS the song
                    // and the text its artist, which is the whole answer, tappable.
                    // `found` rides along so the tap can open the album rather
                    // than just the app. See notifyResult.
                    notifyResult(title, text, found = found)
                    result.success(null)
                    tearDownHeadless()
                } else {
                    result.notImplemented()
                }
            }

            // The library URI is required: without it the engine only searches the root
            // library (package:auvy/main.dart), never finds `headlessRecognitionMain`,
            // and silently runs nothing until the timeout. Keep this in step with the
            // file path if the entrypoint ever moves.
            engine.dartExecutor.executeDartEntrypoint(
                io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "auvyHeadlessRecognitionMain",
                ),
            )

            // Backstop: if Dart never reports (no network, a throw before the channel is
            // wired), say so and tear the engine down rather than leaving the
            // notification on "Identifying…". If no phase at all was reported within 10s,
            // the isolate never started, so fail early instead of waiting the full time.
            mainHandler.postDelayed({
                if (headlessEngine != null && lastHeadlessPhase == PHASE_NONE) {
                    Log.w(TAG, "headless engine never reached Dart — entrypoint " +
                        "missing or tree-shaken? Giving up early.")
                    notifyResult("Could not identify", "Tap to try again in Auvy.")
                    tearDownHeadless()
                }
            }, HEADLESS_BOOT_TIMEOUT_MS)

            mainHandler.postDelayed({
                if (headlessEngine != null) {
                    Log.w(TAG, "headless recognition timed out " +
                        "(last phase: $lastHeadlessPhase)")
                    notifyResult("Could not identify", "Tap to try again in Auvy.")
                    tearDownHeadless()
                }
            }, HEADLESS_TIMEOUT_MS)
        } catch (e: Exception) {
            Log.w(TAG, "headless engine failed: ${e.javaClass.simpleName} ${e.message}")
            notifyResult("Audio captured", "Tap to identify it in Auvy.")
            tearDownHeadless()
        }
    }

    /**
     * Give the headless engine ONLY the plugins the recogniser actually uses.
     *
     * Never use GeneratedPluginRegistrant here: it registers audio_service and
     * audio_session, which keep process-wide static state and assume one engine
     * per process. A second registration (and that engine later being destroyed)
     * leaves them pointing at a dead isolate, breaking playback when the app is
     * opened in the same process.
     *
     * What the headless path needs:
     * • shared_preferences: the pending-capture marker and recognition history.
     * • path_provider: file locations.
     * • record: SongRecognitionService creates an `AudioRecorder` in a field
     *   initializer, so the channel must exist even though nothing records here.
     * `http` is pure Dart and needs no plugin.
     *
     * A missing plugin shows up as MissingPluginException in the phase log.
     */
    private fun registerHeadlessPlugins(engine: io.flutter.embedding.engine.FlutterEngine) {
        fun add(name: String, make: () -> io.flutter.embedding.engine.plugins.FlutterPlugin) {
            try {
                engine.plugins.add(make())
            } catch (e: Exception) {
                Log.w(TAG, "headless plugin $name failed: ${e.javaClass.simpleName}")
            }
        }
        add("shared_preferences") {
            io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin()
        }
        add("path_provider") { io.flutter.plugins.pathprovider.PathProviderPlugin() }
        add("record") { com.llfbandit.record.RecordPlugin() }
    }

    /**
     * Destroy the headless engine and release the service that was keeping the
     * process alive for it. Safe to call twice — both the result path and the
     * timeout call it, and whichever loses the race must be a no-op.
     */
    private fun tearDownHeadless() {
        headlessPending = false
        val e = headlessEngine
        headlessEngine = null
        if (e != null) {
            try { e.destroy() } catch (_: Exception) {}
        }
        // The only reason the service was still running.
        stopSelf()

        // Retire the process after headless work. Even after the engine is destroyed,
        // plugin singletons and static state initialised by it remain, and
        // MainActivity starting in the same process can come up half initialised
        // (missing playlists, a stuck player). A fresh process avoids that.
        //
        // Only done while no UI exists, checked at kill time, since the user may
        // have opened the app in the meantime.
        //
        // Uses a separate Handler rather than `mainHandler`: stopSelf() leads to
        // onDestroy(), which clears mainHandler's callbacks and would cancel this.
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            if (onCaptureReady == null && !appHasVisibleUi()) {
                Log.i(TAG, "headless work finished — retiring this process so the " +
                    "next launch starts clean")
                android.os.Process.killProcess(android.os.Process.myPid())
            } else {
                Log.i(TAG, "app came up while finishing — leaving the process alone")
            }
        }, PROCESS_RETIRE_DELAY_MS)
    }

    /**
     * Does this process currently have a MainActivity? Used to veto retiring the
     * process after headless work. (Process importance can't answer this: the
     * foreground service itself makes the process look visible.)
     */
    private fun appHasVisibleUi(): Boolean = MainActivity.liveActivities > 0

    /** Straight microphone PCM, same format the fingerprinter already expects. */
    private fun micRecord(seconds: Double): ByteArray? {
        var record: AudioRecord? = null
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(4096)
            // Pick an audio source suited to MUSIC. MIC and especially VOICE_RECOGNITION
            // apply speech processing (gain control, noise suppression, band-limiting)
            // that flattens the spectral peaks a fingerprint depends on.
            //
            // Order, best first:
            //   UNPROCESSED: raw, no DSP (optional hardware support).
            //   CAMCORDER:   tuned for recording content, wide-band, minimal processing.
            //   MIC:         the plain default.
            // VOICE_RECOGNITION is deliberately excluded.
            val unprocessedOk = try {
                (getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager)
                    .getProperty(
                        android.media.AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED
                    ) == "true"
            } catch (_: Exception) {
                false
            }
            val candidates = buildList {
                if (unprocessedOk) {
                    add("UNPROCESSED" to android.media.MediaRecorder.AudioSource.UNPROCESSED)
                }
                add("CAMCORDER" to android.media.MediaRecorder.AudioSource.CAMCORDER)
                add("MIC" to android.media.MediaRecorder.AudioSource.MIC)
            }

            // Some devices advertise a source they cannot actually open, so this
            // walks the list rather than assuming the first one works.
            var chosen: String? = null
            for ((name, src) in candidates) {
                val candidate = try {
                    AudioRecord(
                        src,
                        SAMPLE_RATE,
                        AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT,
                        minBuf * 4,
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "mic source $name threw ${e.javaClass.simpleName}")
                    null
                }
                if (candidate != null && candidate.state == AudioRecord.STATE_INITIALIZED) {
                    record = candidate
                    chosen = name
                    break
                }
                try { candidate?.release() } catch (_: Exception) {}
                Log.w(TAG, "mic source $name failed to initialise")
            }
            val rec = record
            if (rec == null || rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "mic AudioRecord failed to initialise")
                return null
            }
            Log.i(TAG, "mic source=$chosen")

            // Explicitly turn off AGC, noise suppression and echo cancellation: Android
            // may attach them regardless of the source, and they mangle music. All three
            // are optional; `create` returns null where unsupported.
            try {
                val sid = rec.audioSessionId
                android.media.audiofx.AutomaticGainControl.create(sid)?.apply {
                    enabled = false
                }
                android.media.audiofx.NoiseSuppressor.create(sid)?.apply {
                    enabled = false
                }
                android.media.audiofx.AcousticEchoCanceler.create(sid)?.apply {
                    enabled = false
                }
            } catch (e: Exception) {
                Log.w(TAG, "could not disable capture effects: ${e.javaClass.simpleName}")
            }
            val wanted = (SAMPLE_RATE * 2 * seconds).toInt()
            val out = java.io.ByteArrayOutputStream(wanted)
            val chunk = ByteArray(minBuf)
            rec.startRecording()
            while (out.size() < wanted) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n <= 0) break
                out.write(chunk, 0, n)
            }
            val pcm = out.toByteArray()

            // Log peak and RMS so a "no match" can be diagnosed: silence vs a capture
            // that failed to fingerprint (a byte count can't tell them apart). These are
            // just loudness figures and carry no content. Roughly: peak under ~500 is a
            // silent room; music from a speaker is in the thousands.
            var peak = 0
            var sumSq = 0.0
            var i = 0
            while (i + 1 < pcm.size) {
                val s = ((pcm[i + 1].toInt() shl 8) or (pcm[i].toInt() and 0xFF)).toShort().toInt()
                val a = if (s < 0) -s else s
                if (a > peak) peak = a
                sumSq += (s.toDouble() * s.toDouble())
                i += 2
            }
            val rms = if (pcm.size >= 2) Math.sqrt(sumSq / (pcm.size / 2)).toInt() else 0
            Log.i(TAG, "mic level peak=$peak rms=$rms (${pcm.size} bytes, source=$chosen)")
            return pcm
        } finally {
            try { record?.stop() } catch (_: Exception) {}
            try { record?.release() } catch (_: Exception) {}
        }
    }

    /**
     * Records [seconds] of playback audio. Returns null when nothing usable came
     * through — including the case where the stream is valid but SILENT, which is
     * what an app that opts out of capture produces. Without that check the
     * fingerprinter would be handed silence and the user told "no match", which
     * points them at entirely the wrong problem.
     */
    private fun record(projection: MediaProjection, seconds: Double): ByteArray? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        isCapturing = true
        var record: AudioRecord? = null
        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(projection)
                // UNKNOWN included because plenty of apps never set an attribute and
                // would otherwise be silently uncapturable.
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(4096)

            record = AudioRecord.Builder()
                .setAudioFormat(format)
                // Generous: an undersized buffer drops samples under GC pressure and
                // a gap mid-capture corrupts the fingerprint.
                .setBufferSizeInBytes(minBuf * 4)
                .setAudioPlaybackCaptureConfig(config)
                .build()
            if (record.state != AudioRecord.STATE_INITIALIZED) return null

            val wanted = (SAMPLE_RATE * 2 * seconds).toInt()
            val out = java.io.ByteArrayOutputStream(wanted)
            val chunk = ByteArray(minBuf)
            var silent = 0
            record.startRecording()
            while (out.size() < wanted) {
                val n = record.read(chunk, 0, chunk.size)
                if (n <= 0) break
                out.write(chunk, 0, n)
                if (isSilent(chunk, n)) silent += n
            }
            record.stop()
            val bytes = out.toByteArray()
            val ratio = if (bytes.isEmpty()) 1.0 else silent.toDouble() / bytes.size
            Log.i(TAG, "captured ${bytes.size} bytes silence=${"%.2f".format(ratio)}")
            return if (bytes.size < SAMPLE_RATE || ratio > 0.95) null else bytes
        } catch (e: Exception) {
            Log.w(TAG, "record failed: ${e.message}")
            return null
        } finally {
            try { record?.release() } catch (_: Exception) {}
            isCapturing = false
        }
    }

    private fun isSilent(buf: ByteArray, len: Int): Boolean {
        var i = 0
        while (i + 1 < len) {
            val s = ((buf[i + 1].toInt() shl 8) or (buf[i].toInt() and 0xFF)).toShort()
            if (kotlin.math.abs(s.toInt()) > 24) return false
            i += 2
        }
        return true
    }

    private fun finishOneShot(bytes: ByteArray?) {
        val cb = onResult
        onResult = null
        mainHandler.post { cb?.invoke(bytes) }
        // When a result is showing, notifyResult has ALREADY dropped foreground
        // state and re-posted the answer as a plain notification, so there is
        // nothing to detach and calling REMOVE here would delete it. Only the
        // no-result case still needs clearing: a bare "Listening…" left behind by
        // a cancelled or failed capture is litter.
        if (!resultShowing) {
            try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
        }
        stopSelf()
    }

    /// Posts the capture's status notification.
    ///
    /// [found] carries the matched track into the tap, so tapping the result opens
    /// it (the same as the in-app path).
    /// [terminal] false = a progress update ("Identifying…"), true = the answer.
    ///
    /// Uses the same id as the foreground-service notification, so the user sees
    /// one notification that advances Listening… → Identifying… → the track.
    private fun notifyResult(
        title: String,
        text: String,
        found: Boolean = false,
        terminal: Boolean = true,
    ) {
        // Always, not only for the final answer: the in-app path posts
        // "Identifying…" and stops the service immediately, and the notification
        // would be removed with it. Every call site runs after recording has
        // finished, so no microphone obligation remains here.
        resultShowing = true
        run {
            // Drop foreground state before posting. A notification still flagged as the
            // foreground service's is removed when the process goes away, and this
            // service stops (and retires its process) seconds after identifying, so the
            // answer would vanish. After this, notify() creates a plain notification that
            // survives both, reusing the same id so it updates in place.
            try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
        }
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(
                NOTIF_ID,
                Notification.Builder(this, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                    .setAutoCancel(true)
                    .setContentIntent(openAppIntent(if (found) "$title $text" else null))
                    .build()
            )
        } catch (_: Exception) {
        }
    }

    /// [foundTrack] is `"<title> <artist>"`, the exact shape MainActivity's
    /// `consumeFoundTap` hands to Dart. Null for a failure notification, which
    /// should just open the app.
    private fun openAppIntent(foundTrack: String? = null): PendingIntent {
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (foundTrack != null) intent.putExtra(MainActivity.EXTRA_FOUND, foundTrack)
        return PendingIntent.getActivity(
            this,
            // Distinct request code per payload, OR the extra is ignored.
            // FLAG_UPDATE_CURRENT only refreshes extras when the PendingIntent is
            // otherwise equal, and equality does NOT consider extras, so reusing
            // code 0 for every result would leave the FIRST match's track attached
            // to every later notification.
            if (foundTrack != null) foundTrack.hashCode() else 0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /// The foreground-service notification. [listening] is the mic path.
    private fun buildNotification(listening: Boolean = false): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // LOW: this exists because the OS mandates it while a projection is
            // held, not because the user needs telling.
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Audio recognition", NotificationManager.IMPORTANCE_LOW
                ).apply { setShowBadge(false) }
            )
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(
                when {
                    listening -> "Listening…"
                    else -> "Identifying audio"
                }
            )
            .setContentText(
                when {
                    listening -> "Hearing what is playing around you."
                    else -> "Listening to this device's audio…"
                }
            )
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(openAppIntent())
            .build()
    }

    override fun onDestroy() {
        // Any waiting one-shot call must still be answered or the sheet hangs.
        onResult?.let { cb ->
            onResult = null
            mainHandler.post { cb(null) }
        }
        // A FlutterEngine holds a Dart VM isolate and native resources. If the
        // system tears this service down mid-recognition, destroying it here is the
        // only thing that reclaims them — nothing else has a reference.
        headlessPending = false
        headlessEngine?.let { e ->
            headlessEngine = null
            try { e.destroy() } catch (_: Exception) {}
        }
        mainHandler.removeCallbacksAndMessages(null)
        releaseProjection()
        super.onDestroy()
    }
}
