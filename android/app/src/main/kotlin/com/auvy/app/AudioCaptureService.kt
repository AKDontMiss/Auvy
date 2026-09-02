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
 * Captures the audio ANOTHER app is playing, so recognition can identify music in
 * Instagram, a browser, a game — anything on this device.
 *
 * ## Two modes, and why
 *
 * **One-shot** ([ACTION_ONESHOT]) — used by the in-app long-press. Acquires a
 * projection, records, hands the PCM back through [onResult], stops. Only works for
 * audio that keeps playing while Auvy is foreground.
 *
 * **Armed** ([ACTION_ARM] → many [ACTION_CAPTURE] → [ACTION_DISARM]) — used by the
 * quick-settings tile. This exists because Instagram Reels PAUSE the moment the app
 * loses focus, so anything that requires opening Auvy first cannot identify them.
 *
 * The armed mode turns on one crucial property: `MediaProjection` only prompts the
 * user when it is ACQUIRED, never when it is used. Holding a single projection open
 * therefore means every later tile tap captures with **no dialog at all** — the user
 * stays in Instagram and the reel never pauses. Re-acquiring per capture would put
 * the system consent dialog over Instagram every single time, pausing the reel and
 * defeating the entire feature.
 *
 * The unavoidable cost, and it must be surfaced in the UI: Android requires a
 * persistent notification for as long as a projection is held.
 *
 * ## Why the tile doesn't identify anything
 * Recognition (Shazam signature + query) is Dart code, and Auvy's Flutter engine
 * generally isn't running while the user is in another app. So a tile capture writes
 * raw PCM to a temp file and records a marker pref; Dart picks it up and identifies
 * it the next time Auvy is foreground. The fragile half (audio still playing) is
 * protected natively; the half that needs UI happens where the UI already is.
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
        const val ACTION_ARM = "com.auvy.app.CAPTURE_ARM"
        const val ACTION_CAPTURE = "com.auvy.app.CAPTURE_NOW"
        /** Record from the MICROPHONE — the tile's path. No projection needed. */
        const val ACTION_MIC = "com.auvy.app.CAPTURE_MIC"
        const val ACTION_DISARM = "com.auvy.app.CAPTURE_DISARM"


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

        /** Held only in ARMED mode, so tile captures need no further consent. */
        @Volatile
        private var armedProjection: MediaProjection? = null

        val isArmed: Boolean get() = armedProjection != null

        /// How long the live engine gets to acknowledge a handoff before the headless
        /// path takes over. Short on purpose: Dart only has to accept the work, and
        /// every extra second is silence on the notification.
        private const val HANDOFF_TIMEOUT_MS = 1500L

        /// Asks Dart to identify a capture that has just been written, reporting
        /// through [ack] whether Dart actually took the work.
        ///
        /// The ack exists because a non-null listener does NOT mean a live engine.
        ///
        /// This was a plain `() -> Unit`, and the doc claimed "null when no Flutter
        /// engine is alive, so it is a reliable test". It is not: MainActivity assigns
        /// it in configureFlutterEngine and NOTHING clears it, so after the first
        /// launch it stays non-null for the life of the PROCESS — including after the
        /// activity and its engine are gone.
        ///
        /// The service therefore always believed something was listening, never
        /// started the headless engine, and the capture sat pending until the user
        /// opened the app. Observed exactly that way: the tile said "Identifying…",
        /// nothing else happened, and the answer appeared on re-entering Auvy.
        ///
        /// Clearing it on destroy is NOT the fix — audio_service caches the engine,
        /// so a destroyed activity can still have a good isolate behind it, and
        /// forcing the headless path there would build a second engine in this
        /// process (see runHeadlessRecognition for why that is unsafe). Asking, and
        /// falling back only when no answer arrives, is right in both cases.
        @Volatile
        var onCaptureReady: ((ack: (Boolean) -> Unit) -> Unit)? = null

        /** True while a capture is running, so the tile can't stack them.
         *
         * VOLATILE IS NOT ENOUGH — IT MUST BE CLAIMED BEFORE THE WORKER STARTS.
         *
         * This is a check-then-act guard spanning two threads: onStartCommand READS
         * it on the main thread, and it used to be SET inside record(), which runs on
         * the worker. Volatility makes each access atomic; it does nothing about the
         * GAP between the check and the set. Two tile taps in quick succession
         * therefore both saw false and both started a capture — two AudioRecords on
         * one MediaProjection, a corrupted fingerprint, and a second recorder to
         * leak if either path threw before its finally.
         *
         * onStartCommand now claims it on the same thread that checks it, and
         * captureToFile clears it in a finally so no exit path can leave the tile
         * permanently "busy".
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
        // Foreground FIRST, always: from API 34 MediaProjection is refused unless a
        // mediaProjection-typed FGS is already running.
        //
        // AND THE TYPE MUST MATCH THE SOURCE. A mic capture started under the
        // mediaProjection type is rejected on API 34+ (and vice versa), so the type
        // is chosen from the action rather than fixed. The manifest declares both.
        // A MIC FGS WITHOUT RECORD_AUDIO IS A PROCESS KILL, NOT AN ERROR CODE.
        //
        // startForeground(…, MICROPHONE) throws SecurityException when RECORD_AUDIO
        // is not granted — from inside onStartCommand, so it takes the whole app
        // down. Observed exactly that: "Starting FGS with type microphone …
        // requires … anyOf [… RECORD_AUDIO]". The tile checks the permission too,
        // but the check has to live HERE as well: this service is startable from
        // several places and only it knows which type it is about to claim.
        if (action == ACTION_MIC &&
            checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
            != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "mic capture refused — RECORD_AUDIO not granted")
            notifyResult("Microphone needed", "Open Auvy once to allow the microphone.")
            stopSelf()
            return START_NOT_STICKY
        }

        val notif = buildNotification(
            // ACTION_MIC is neither one-shot-with-projection nor armed-and-waiting:
            // it is listening, right now, because the user just asked it to.
            armed = action != ACTION_ONESHOT && action != ACTION_MIC,
            listening = action == ACTION_MIC,
        )
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
            ACTION_DISARM -> {
                releaseProjection()
                stopSelf()
            }
            ACTION_ARM -> {
                val code = intent!!.getIntExtra(EXTRA_RESULT_CODE, 0)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                if (data == null || !acquireProjection(code, data)) {
                    Log.w(TAG, "arm failed")
                    stopSelf()
                } else {
                    Log.i(TAG, "armed — tile captures need no further consent")
                }
            }
            // MIC CAPTURE: how the tile works now
            //
            // No MediaProjection, no consent dialog, no screen sharing. The
            // microphone hears the phone's own speaker, so whatever Instagram (or
            // anything else) is playing out loud is identifiable, which is how
            // Shazam's Auto Shazam tile does it.
            //
            // Needs RECORD_AUDIO granted and FOREGROUND_SERVICE_MICROPHONE
            // declared; without the latter this throws SecurityException on API
            // 34+, which is the mistake that sent this feature down the
            // screen-sharing route in the first place. See the manifest note.
            ACTION_MIC -> {
                if (isCapturing) {
                    Log.w(TAG, "mic capture ignored — already capturing")
                } else {
                    val seconds = intent?.getDoubleExtra(EXTRA_SECONDS, 8.0) ?: 8.0
                    isCapturing = true
                    Thread { micToFile(seconds) }.start()
                }
            }
            ACTION_CAPTURE -> {
                val projection = armedProjection
                if (projection == null || isCapturing) {
                    Log.w(TAG, "capture ignored (armed=${projection != null} busy=$isCapturing)")
                } else {
                    val seconds = intent!!.getDoubleExtra(EXTRA_SECONDS, 8.0)
                    // Claim it HERE, on the same thread that just checked it, so
                    // check-and-set cannot be interleaved. record() sets it again
                    // (harmless) and clears it in its finally.
                    isCapturing = true
                    Thread { captureToFile(projection, seconds) }.start()
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
            // revokes capture from the status bar — treat that as a full disarm so
            // the tile stops pretending to work.
            p.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.i(TAG, "projection stopped externally → disarm")
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

    /** Tile path: capture, write PCM to a temp file, leave a marker for Dart. */
    private fun captureToFile(projection: MediaProjection, seconds: Double) {
        // The busy flag must clear on every path out of here.
        //
        // onStartCommand claims it before spawning this thread (so check-and-set
        // cannot interleave), and record() clears it in its own finally — but
        // record() RETURNS EARLY when SDK_INT < Q, before that finally exists. On
        // such a device the flag would stay set forever and every later tile tap
        // would be ignored as "busy". Clearing it here too makes a lockout
        // impossible regardless of how record() exits.
        try {
            captureToFileInner(projection, seconds)
        } finally {
            isCapturing = false
        }
    }

    private fun captureToFileInner(projection: MediaProjection, seconds: Double) {
        val bytes = record(projection, seconds)
        if (bytes == null) {
            notifyResult("Nothing to identify", "No capturable audio was playing.")
            return
        }
        try {
            val f = File(cacheDir, PENDING_FILE)
            f.writeBytes(bytes)
            getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit().putString(PREF_PENDING, f.absolutePath).apply()
            Log.i(TAG, "pending capture written: ${bytes.size} bytes")
            //"Open Auvy to see the match" WAS THE WRONG ANSWER. The user asked
            // a question and got homework. This now reads as work in progress, and
            // the hook below asks Dart to identify immediately and REPLACE this
            // notification with the actual song.
            notifyResult("Identifying…", "Listening to what is playing.",
                terminal = false)
            // Fires only if a Flutter engine is alive to answer (MainActivity wires
            // it). When nothing is listening the pending file stays exactly as
            // before, and the app identifies it on next open, so this is a
            // fast path, never the only path.
            // Best-effort: this path already leaves the file pending, and the ack
            // only matters where a missed handoff means nothing ever identifies it.
            try { onCaptureReady?.invoke { } } catch (_: Exception) {}
        } catch (e: Exception) {
            Log.w(TAG, "write failed: ${e.message}")
            notifyResult("Capture failed", "Could not save the audio.")
        }
    }

    /**
     * Records [seconds] of playback audio. Returns null when nothing usable came
     * through — including the case where the stream is valid but SILENT, which is
     * what an app that opts out of capture produces. Without that check the
     * fingerprinter would be handed silence and the user told "no match", which
     * points them at entirely the wrong problem.
     */
    /**
     * Mic capture: record, write, notify, hand to Dart. Mirrors captureToFile's
     * contract exactly so the rest of the pipeline (pending file, onCaptureReady,
     * identification) is shared and cannot drift between the two sources.
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

            // ONLY PROMISE "IDENTIFYING" IF SOMETHING IS ACTUALLY LISTENING.
            //
            // The fingerprinting lives in Dart, so it needs a live Flutter engine.
            // When Auvy has been closed and the process was cold-started by the
            // tile, there is no engine, and the notification used to sit on
            // "Identifying…" for ever, which reads as a hang. The user then opened
            // the app, the pending file was picked up, and the answer appeared,
            // making it look as though opening the app were a required step.
            //
            // `onCaptureReady` is non-null exactly when an engine is wired up, so it
            // is a reliable test for which of the two things we can honestly say.
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
            // Do NOT stop while a headless recognition is pending.
            //
            // This called stopSelf() unconditionally, including immediately after
            // starting the headless engine. Ending the foreground service is what
            // was keeping the process alive and foreground, so identification was
            // then racing Android's willingness to kill it, which is exactly the
            // "takes ages, then no match" with the app closed. The service now lives
            // until the engine reports or times out; tearDownHeadless stops it.
            if (!headlessPending) stopSelf()
        }
    }

    /**
     * Run the Dart recogniser with NO ACTIVITY, so a tile capture is identified
     * even with Auvy closed.
     *
     * WHY THIS IS NEEDED AT ALL. Fingerprinting and the catalogue lookup are
     * Dart. With the app closed there was no engine to run them, so the capture sat
     * on disk and the notification could only say "tap to identify in Auvy" —
     * turning a one-tap feature into a two-step errand.
     *
     * Three things make a hand-built engine work where a naive one fails:
     *
     *  • FlutterLoader must be initialised before the engine is constructed, or the
     *    Dart snapshot cannot be found. It is idempotent, so initialising here is
     *    safe whether or not the app has run this process.
     *  • GeneratedPluginRegistrant.registerWith is MANDATORY. An engine created by
     *    hand has no plugins — shared_preferences and path_provider would both
     *    throw MissingPluginException, and the recogniser needs them.
     *  • The entrypoint is looked up BY NAME, so the Dart function must carry
     *    `@pragma('vm:entry-point')` or release tree-shaking removes it and the
     *    engine boots into nothing.
     *
     * Torn down on the result, and on a timeout, because an engine left running
     * would hold the process alive indefinitely for a job that lasts seconds.
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
                    // The only window into this path in a release build.
                    //
                    // Release swallows every Dart print(), and a headless isolate has
                    // no UI, so a run that stalls produced exactly one line — "timed
                    // out" — with no way to tell a missing plugin from a slow network
                    // from a hang before the first await. Dart now names each step as
                    // it passes; the timeout below reports the last one reached.
                    //
                    // Phase names are compile-time constants (`captured`, `matched`…)
                    // — never a title, artist, query or path, so this stays safe to
                    // ship. See the report() helper in headless_recognition.dart.
                    lastHeadlessPhase = call.argument<String>("name") ?: "?"
                    Log.i(TAG, "headless phase: $lastHeadlessPhase")
                    result.success(null)
                } else if (call.method == "result") {
                    val title = call.argument<String>("title") ?: "No match"
                    val text = call.argument<String>("text") ?: ""
                    val found = call.argument<Boolean>("found") ?: false
                    // ON A FAILURE, SAY WHICH FAILURE. `found=false` covers
                    // "no match", "rate limited", "Shazam 5xx" and "not enough
                    // audio" — four different problems with four different fixes,
                    // and one flag cannot tell them apart. On the failure path the
                    // title is one of this app's own constant strings, never a
                    // song, artist or query, so it is safe to log in a release
                    // build. A MATCH logs nothing but the flag: that title IS user
                    // content (what they were listening to) and does not belong in
                    // logcat, where any app with log access could read it.
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

            // The library uri is mandatory, AND its absence fails silently.
            //
            // The two-argument DartEntrypoint(bundlePath, functionName) sets
            // `dartEntrypointLibrary = null`, and the engine then looks the name
            // up in the ROOT library only — package:auvy/main.dart.
            // `headlessRecognitionMain` lives in its own file, so it was never
            // found: the engine started, had no entrypoint to run, and sat there
            // until the 25-second backstop fired.
            //
            // Nothing reported that. There is no "entrypoint not found" callback,
            // no exception to catch, and the isolate produces no output — from
            // the outside it is indistinguishable from a slow network, which is
            // exactly how it was misread ("takes ages, then no match"). The phase
            // log proved it: `last phase: not started`, meaning Dart had not
            // executed a single line.
            //
            // Naming the library makes the lookup explicit. Keep this in step
            // with the file path if the entrypoint ever moves — a rename here is
            // silent in exactly the same way.
            engine.dartExecutor.executeDartEntrypoint(
                io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "auvyHeadlessRecognitionMain",
                ),
            )

            // Backstop: if Dart never reports (no network, a throw before the
            // channel is wired), say so and reclaim the engine rather than leaving
            // the notification on "Identifying…" and the process pinned.
            // Did it even boot?
            // A missing entrypoint is not slow, it is DEAD — no amount of extra
            // waiting will produce an answer. Distinguishing the two matters to
            // the user: "could not identify" after ten seconds is a result,
            // whereas twenty-five seconds of nothing reads as the app being
            // broken. Ten seconds is far beyond any plausible cold Dart boot, so
            // a phase count of zero by then means the isolate never ran.
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
     * NEVER GeneratedPluginRegistrant HERE — IT BREAKS PLAYBACK IN THE APP.
     *
     * That helper registers everything the app has, which includes
     * `AudioServicePlugin` and `AudioSessionPlugin` — the plugins that own
     * playback — plus Firebase, WebView, Google Sign-In and the image picker.
     * audio_service keeps STATIC, process-wide state and assumes exactly one
     * engine per process; a second registration, followed by that engine being
     * destroyed on a timeout, leaves its statics pointing at a dead isolate.
     *
     * Observed exactly that way: tile tap with Auvy closed → headless engine in a
     * fresh process → timeout → engine destroyed → user taps the notification →
     * MainActivity starts IN THE SAME PROCESS → audio_service takes 30 SECONDS to
     * reach the foreground (`startForegroundDelayMs:30182` in the ActivityManager
     * log) and playback does nothing. Registering the app's audio stack onto a
     * throwaway engine inside the media app's own process cannot be made safe;
     * the fix is not to do it.
     *
     * What the headless path genuinely needs, and nothing else:
     *  • shared_preferences — the pending-capture marker and the recognition
     *    history that a match is written to.
     *  • path_provider — file locations under the capture path.
     *  • record — SongRecognitionService constructs an `AudioRecorder` in a FIELD
     *    initializer, so the channel must exist even though the headless path
     *    never records (it identifies PCM the native side already captured).
     * `http` is pure Dart and needs no plugin.
     *
     * A plugin missing here surfaces as MissingPluginException in the phase log
     * added below — which is a legible failure, unlike the one this replaced.
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

        // RETIRE THE PROCESS. A PROCESS THAT HAS HOSTED A HEADLESS ENGINE IS
        // Not fit to host the app.
        //
        // Destroying the engine does not undo what running it did to the process.
        // Plugin singletons, the Dart VM's loaded state and media3's static
        // objects were all initialised by an engine that no longer exists, and
        // MainActivity starting in that same process inherits the wreckage —
        // observed exactly as reported: the app opens "half initialised", the
        // library comes up with playlists missing and the player shows 00:00 with
        // a start and end timestamp that never advance.
        //
        // Cutting the plugin set down (see registerHeadlessPlugins) reduced this
        // but could not eliminate it, because the problem is not any single
        // plugin — it is that one process cannot cleanly host two lifetimes.
        // Android's own answer is a fresh process, and the headless job is over,
        // so there is nothing left here worth keeping alive.
        //
        // Killing is safe ONLY while no UI exists, which is the very condition
        // that sent us down the headless path. Re-checked at kill time rather
        // than assumed, because the user may have tapped the notification in the
        // meantime, and killing their freshly-opened app would be a far worse
        // bug than the one being fixed.
        // A SEPARATE HANDLER, NOT `mainHandler`. THE SERVICE CANCELS ITS OWN.
        //
        // stopSelf() above leads to onDestroy(), which calls
        // `mainHandler.removeCallbacksAndMessages(null)`, so a retirement posted
        // on mainHandler is cancelled by the very teardown that scheduled it.
        // Verified on device: the process survived, with neither branch of this
        // ever logging.
        //
        // removeCallbacksAndMessages only clears messages targeted at the handler
        // it is called on, so an independent instance on the same looper outlives
        // the service, which is exactly what is needed, since the whole point is
        // to act AFTER the service is gone.
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
     * Does this process currently have a MainActivity?
     *
     * The veto on retiring the process after headless work.
     *
     * NOT PROCESS IMPORTANCE. That was the first attempt and it cannot answer
     * this: a foreground SERVICE reports importance 125, inside the "visible"
     * band, so this service's own existence made the app look open and cancelled
     * its own retirement — logged as "app came up while finishing" with nothing
     * on screen. An Activity counter cannot be fooled that way, and it is already
     * true from onCreate, which is the window that matters.
     */
    private fun appHasVisibleUi(): Boolean = MainActivity.liveActivities > 0

    /** Straight microphone PCM, same format the fingerprinter already expects. */
    private fun micRecord(seconds: Double): ByteArray? {
        var record: AudioRecord? = null
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(4096)
            // AudioSource.MIC IS TUNED FOR SPEECH, AND IT RUINS FINGERPRINTS.
            //
            // MIC runs the signal through automatic gain control and noise
            // suppression aimed at voice: it pumps the level, ducks steady tones and
            // treats sustained music as background to be removed. Fingerprinting
            // depends on exactly the spectral peaks that processing flattens, which
            // is why every capture came back "no match".
            //
            // AND VOICE_RECOGNITION IS THE WORST OF THE LOT — IT WAS THE FALLBACK.
            //
            // The reasoning above was right and the conclusion was backwards. This
            // picked VOICE_RECOGNITION whenever UNPROCESSED was unavailable, which
            // on this device is ALWAYS (every capture logged
            // `mic source=VOICE_RECOGNITION`). That source is not "MIC without
            // AGC" — it is the most aggressively speech-tuned input Android
            // exposes, built for a recogniser listening to a person: noise
            // suppression, band-limiting and gain shaping, all of which target
            // precisely the sustained spectral peaks a music fingerprint is made
            // of. Every capture was being cleaned of the thing we needed.
            //
            // Correct order for MUSIC, best first:
            //   UNPROCESSED — raw, no DSP. Optional hardware support.
            //   CAMCORDER   — tuned for recording CONTENT rather than a talker;
            //                 wide-band, minimal voice processing.
            //   MIC         — the plain default. Some processing, but not aimed at
            //                 isolating speech.
            // VOICE_RECOGNITION is deliberately not in the list.
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

            // CHOOSING THE SOURCE IS NOT ENOUGH — THE EFFECTS ATTACH ANYWAY.
            //
            // Android may bind AGC, noise suppression and echo cancellation to the
            // capture session regardless of which source was requested, and each of
            // them mangles music in the same way the wrong source does. They are
            // per-session and OFF is not the default on every device, so they are
            // turned off explicitly. All three are optional hardware features:
            // `create` returns null where unsupported, which is fine.
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

            //"NO MATCH" HAS TWO CAUSES AND THEY NEED DIFFERENT FIXES: nothing
            // was playing, or something was playing and the fingerprint failed.
            // A byte count cannot tell them apart — a silent capture is exactly as
            // many bytes as a loud one, and that ambiguity is why every failed
            // identification so far has been undiagnosable.
            //
            // Peak and RMS are two integers derived from the waveform. They carry
            // no content: you cannot reconstruct or identify audio from a loudness
            // figure, so this is safe to ship. Roughly: peak under ~500 is a silent
            // room, and a healthy capture of music from a speaker sits in the
            // thousands.
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

    /**
     * Result of a TILE capture. A separate one-shot notification, not the ongoing
     * one: the ongoing notification must survive so the projection stays armed.
     */
    /// [found] carries the answer INTO the tap.
    ///
    /// A HEADLESS MATCH USED TO OPEN THE APP AND STOP THERE. Naming the song in
    /// the notification and then dropping the user on the home screen is the least
    /// useful place to leave them — the whole point of identifying a track is to go
    /// and hear it.
    ///
    /// The machinery for this already existed and the headless path simply was not
    /// wired to it: `EXTRA_FOUND` was attached only in MainActivity's `notifyFound`
    /// handler, which is the IN-APP path. So identifying with Auvy open took you to
    /// the album, and identifying with it closed — the case the tile exists for —
    /// did not.
    /// [terminal] false = a progress update ("Identifying…"), true = the answer.
    ///
    /// ONE NOTIFICATION, NOT TWO. This posted to `NOTIF_ID + 1` while the
    /// foreground-service notification sat on `NOTIF_ID`, so the shade showed
    /// BOTH at once, and the pair contradicted each other: the service one still
    /// read "Listening…" while this one already said "Identifying…", and at the
    /// end the track name appeared alongside a stale "Listening…".
    ///
    /// Sharing one id turns them into a single line that advances through the
    /// states in order — Listening… → Identifying… → the track, which is what
    /// the statuses were for in the first place.
    private fun notifyResult(
        title: String,
        text: String,
        found: Boolean = false,
        terminal: Boolean = true,
    ) {
        // ALWAYS, NOT ONLY FOR THE FINAL ANSWER. Doing this for terminal
        // results alone left the IN-APP path broken: there the service hands the
        // capture to the running engine, posts "Identifying…" as a
        // non-terminal update, and stops immediately, and because the
        // notification still belonged to the foreground service, teardown
        // deleted it. The user watched it go Listening… → Identifying… → gone.
        //
        // Every call site runs AFTER recording has finished (the two
        // "Identifying…" posts both follow the capture, and a result follows the
        // lookup), so there is never a microphone obligation left to honour at
        // this point and foreground state can always be released here.
        resultShowing = true
        run {
            // Shed the foreground-service flag before posting, OR Android
            // Deletes the notification.
            //
            // Updating the service's own notification leaves FLAG_FOREGROUND_SERVICE
            // on it, and the system removes a notification carrying that flag when
            // the process goes away. This service always stops seconds after
            // identifying, and now retires its process too, so the track name was
            // being posted and then swept away moments later. Confirmed in
            // `dumpsys notification`: id 8801 sitting there with
            // `flags=NO_CLEAR|FOREGROUND_SERVICE`. That is the "it listens, then
            // just dies" report: the recognition worked every time, the ANSWER was
            // what disappeared.
            //
            // Dropping foreground state first means the notify() below creates a
            // plain, standalone notification that belongs to nobody and survives
            // both the service stopping and the process being retired. Reusing the
            // same id keeps it a single notification that advances in place, rather
            // than a second one appearing beside the first.
            //
            // Safe here specifically: a terminal result only ever happens after
            // recording has finished, so no microphone FGS obligation remains.
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

    /// [listening] is the MIC path, and it must be distinguishable from [armed].
    ///
    /// THE TILE USED TO TELL YOU TO PRESS THE TILE. The call site passed
    /// `armed = action != ACTION_ONESHOT`, which is true for a mic capture — so
    /// tapping the tile raised a notification reading "Tap the Auvy tile in quick
    /// settings while music plays", i.e. instructions to do the thing that had just
    /// been done. And because the real "Identifying…" notice was only posted after
    /// the 8-second recording, that wrong text was all the user saw for those 8
    /// seconds. The phase now travels with the call.
    private fun buildNotification(armed: Boolean, listening: Boolean = false): Notification {
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
                    armed -> "Ready to identify audio"
                    else -> "Identifying audio"
                }
            )
            .setContentText(
                when {
                    listening -> "Hearing what is playing around you."
                    armed -> "Tap the Auvy tile in quick settings while music plays."
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
