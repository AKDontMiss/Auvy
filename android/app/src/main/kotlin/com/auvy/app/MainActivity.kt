package com.auvy.app

import android.util.Log

import android.content.Intent
import android.webkit.CookieManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val playerChannelName = "com.auvy.app/native_player"
    private val cookieChannelName = "com.auvy.app/cookies"
    private val toastChannelName = "com.auvy.app/toast"

    // Pending Dart result for the native sign-in screen (see LoginActivity).
    private var pendingLoginResult: MethodChannel.Result? = null
    // The account chosen in the native picker at last sign-in. Display only.
    private var lastPickedEmail: String? = null
    private val loginRequestCode = 4711

    // Pending Dart result for the Discord Rich Presence sign-in.
    private var pendingDiscordResult: MethodChannel.Result? = null
    private val discordRequestCode = 4713

    // Last toast shown, so a new message can replace it immediately instead of
    // waiting in the OS toast queue behind it.
    private var lastToast: android.widget.Toast? = null

    // Pending early-dismiss for [lastToast]. Android exposes only LENGTH_SHORT
    // (~2s) and LENGTH_LONG (~3.5s) — there is no API for an arbitrary duration —
    // so a shorter toast means showing it and cancelling it ourselves.
    private val toastHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var toastDismiss: Runnable? = null

    // "Capture app audio" recognition. The MediaProjection consent dialog is an
    // Activity result, so the Dart call has to be parked until the user answers.
    private var pendingCaptureResult: MethodChannel.Result? = null
    private var pendingCaptureSeconds: Double = 8.0
    /// True when the pending consent is for ARMING the tile rather than a one-shot
    /// capture — the two take the same dialog but do opposite things with the grant.
    private var pendingCaptureArm: Boolean = false
    private val captureRequestCode = 4715

    /// "title artist" when the activity was opened by tapping a "song found"
    /// notification, so Dart can jump straight to that album. Read-and-cleared.
    private var pendingFoundTap: String? = null

    // Backup files, without "all files access"
    //
    // Raw paths cannot do this job, AND the symptom looked like a bug in the
    // Feature rather than in the storage model.
    //
    // Auvy deliberately holds no MANAGE_EXTERNAL_STORAGE (see the manifest for
    // why — it is the permission Play gates and malware scanners flag). Under
    // scoped storage that means Dart's File API can neither WRITE a .backup into
    // /Download nor LIST what is already there:
    //
    //   • every export fell through to app-private storage, which Android 11+
    //     hides from every file manager, so the file the user was told about was
    //     genuinely unfindable;
    //   • the restore scan could never see a backup written by another app, so a
    //     Metrolist file sitting in Downloads simply did not appear.
    //
    // Both are solved without a single new permission, the same way Metrolist
    // does it (CreateDocument / OpenDocument — never a path):
    //
    //   saveToDownloads  → MediaStore's Downloads collection. Any app may insert
    //                      there on API 29+, and the result is a real file the
    //                      user sees in Files under Download/Auvy.
    //   pickFile         → ACTION_OPEN_DOCUMENT. The user chooses the file, which
    //                      IS the grant, so it works for another app's backup
    //                      anywhere on the device or in cloud storage.
    private var pendingPickResult: MethodChannel.Result? = null
    private val pickFileRequestCode = 4717

    companion object {
        /** Set by RecognizeTileService when the mic still needs granting. */
        const val EXTRA_ASK_MIC = "auvy_ask_mic"
        /// Internal, but NOT private: AudioCaptureService attaches it too, so a
        /// match found headlessly opens the album on tap exactly like an in-app
        /// one. See notifyResult there.
        const val EXTRA_FOUND = "auvy_found_track"

        /// How many MainActivity instances exist right now.
        ///
        /// Exists because process importance cannot answer this question.
        /// AudioCaptureService retires its process after headless work, and must
        /// not do so if the app is on screen. The first attempt asked
        /// ActivityManager for this process's importance, but a foreground
        /// SERVICE reports importance 125, which sits inside the "visible"
        /// threshold, so the service's own existence made the app look open and
        /// silently cancelled the retirement (observed: "app came up while
        /// finishing" with nothing on screen).
        ///
        /// An Activity counter cannot be confused that way. Incremented in
        /// onCreate — before Dart starts, so it is already true during the launch
        /// window when a stale process would do the damage, and never reports a
        /// live Activity that is not there.
        @Volatile
        @JvmStatic
        var liveActivities = 0
        private const val FOUND_CHANNEL = "auvy_found"
        private const val FOUND_NOTIF_ID = 8810

        /** Dart-side key, without Flutter's "flutter." SharedPreferences prefix. */
        private const val SECURE_PREF_KEY = "auvy_block_screenshots"
    }

    /**
     * Opens [path] in a file manager, preferring the device's own.
     *
     * Android has no public "reveal this directory" API, so this walks a list of
     * increasingly generic attempts and stops at the first that resolves:
     *
     *  1. **Samsung My Files** — `samsung.myfiles.intent.action.LAUNCH_MY_FILES`
     *     with a `START_PATH` extra. Undocumented but stable across One UI, and
     *     the only option that lands ON the folder in the app a Samsung owner
     *     actually uses. Tried first for exactly that reason.
     *  2. **DocumentsUI tree URI** — opens Google Files at the folder.
     *  3. **Generic ACTION_VIEW** on a `file://` URI with a folder MIME type, for
     *     third-party managers that still handle the legacy form.
     *
     * Every attempt is wrapped: a file manager that rejects an intent must not
     * take the app down over a convenience button.
     */
    /// Which output media audio is going to: "bluetooth", "headphones", "usb",
    /// "hdmi", "speaker", or null when nothing can be said.
    ///
    /// This is the highest-priority connected output, NOT a read of the actual
    /// ROUTE, because Android does not give ordinary apps the latter.
    /// `AudioManager.getDevicesForAttributes` would answer exactly that question
    /// and is the obvious thing to reach for — it is @SystemApi, gated behind
    /// MODIFY_AUDIO_ROUTING, and does not link in an app build.
    /// `getCommunicationDevice` is public but describes the CALL route, not media.
    ///
    /// So this mirrors the precedence the platform itself applies when several
    /// outputs are connected: Bluetooth, then USB, then wired, then HDMI, then the
    /// built-in speaker. It is right in every ordinary case — plug in headphones
    /// and audio follows them, and can only be wrong when two external outputs
    /// are attached at once and the system picked the other one.
    ///
    /// Only ever drives WHICH ICON is drawn. Nothing routes audio from here, so a
    /// wrong answer costs a slightly off glyph and no behaviour. Null when even
    /// the device list is unavailable, and the button then shows a neutral icon
    /// instead of naming a device that might not exist.
    private lateinit var outputChannel: MethodChannel

    /// Registered only while the output picker is open. See "watchOutputs".
    private var outputWatcher: android.media.AudioDeviceCallback? = null

    private fun currentAudioRoute(): String? {
        try {
            val am = getSystemService(android.content.Context.AUDIO_SERVICE)
                as? android.media.AudioManager ?: return null

            fun label(type: Int): String? = when (type) {
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth"
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET,
                android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "headphones"
                android.media.AudioDeviceInfo.TYPE_USB_DEVICE,
                android.media.AudioDeviceInfo.TYPE_USB_HEADSET,
                android.media.AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
                android.media.AudioDeviceInfo.TYPE_HDMI,
                android.media.AudioDeviceInfo.TYPE_HDMI_ARC -> "hdmi"
                android.media.AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                else -> null
            }

            val outputs: Array<android.media.AudioDeviceInfo> =
                am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
            for (wanted in listOf("bluetooth", "usb", "headphones", "hdmi", "speaker")) {
                for (device in outputs) {
                    if (label(device.type) == wanted) return wanted
                }
            }
            return null
        } catch (_: Exception) {
            return null
        }
    }

    private fun openFolder(path: String): Boolean {
        // 1. Samsung My Files, straight to the path.
        try {
            val intent = Intent("samsung.myfiles.intent.action.LAUNCH_MY_FILES")
                .setPackage("com.sec.android.app.myfiles")
                .putExtra("samsung.myfiles.intent.extra.START_PATH", path)
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}

        // 2. DocumentsUI, addressed the way it addresses shared storage itself:
        //    "primary:" + the path relative to /storage/emulated/0.
        try {
            val rel = path.removePrefix("/storage/emulated/0/").trimStart('/')
            val uri = android.net.Uri.parse(
                "content://com.android.externalstorage.documents/document/" +
                    android.net.Uri.encode("primary:$rel")
            )
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, android.provider.DocumentsContract.Document.MIME_TYPE_DIR)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}

        // 3. Legacy file:// + folder type.
        try {
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(
                    android.net.Uri.parse("file://$path"), "resource/folder")
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                return true
            }
        } catch (_: Exception) {}

        return false
    }

    /** Last value read/applied, so onCreate can restore it without Dart. */
    private fun readSecurePref(): Boolean = try {
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .getBoolean("flutter.$SECURE_PREF_KEY", false)
    } catch (_: Exception) {
        false
    }

    /**
     * Put the CHOSEN icon variant on the recents/task-switcher card.
     *
     * THE ALIASES ONLY EVER FIXED THE LAUNCHER. The recents card takes its icon
     * from the task's ROOT ACTIVITY — MainActivity — which declares no
     * `android:icon` and therefore inherits `<application android:icon>`, the stock
     * blue one. Enabling a colour alias changes the launcher entry and nothing
     * else, so someone on the pink icon still saw blue every time they swiped up.
     *
     * TaskDescription is the API for this, and it has to be applied at RUNTIME:
     * the manifest cannot know which variant is active. Called from onCreate, so
     * the card is right from the first frame rather than after a Dart round-trip.
     */
    /// [forVariant] — the variant to show. Pass it EXPLICITLY from the setIcon
    /// channel: AppIconService writes its pref AFTER the native call returns, so
    /// reading prefs there would pick up the variant being replaced and leave the
    /// recents card one change behind. Null means "read the stored value", which is
    /// correct at cold start, where the pref is already settled.
    private fun applyTaskIcon(forVariant: String? = null) {
        try {
            val variant = forVariant
                ?: getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                    .getString("flutter.auvy_app_icon_variant", "") ?: ""
            // Mirrors AlternateIconManager.aliases — same keys, same order. A
            // variant with no matching mipmap falls back to stock rather than
            // throwing on a missing resource.
            val iconRes = when (variant) {
                "green" -> R.mipmap.ic_launcher_green
                "orange" -> R.mipmap.ic_launcher_orange
                "pink" -> R.mipmap.ic_launcher_pink
                "purple" -> R.mipmap.ic_launcher_purple
                "red" -> R.mipmap.ic_launcher_red
                else -> R.mipmap.ic_launcher
            }
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                setTaskDescription(
                    android.app.ActivityManager.TaskDescription.Builder()
                        .setLabel("Auvy")
                        .setIcon(iconRes)
                        .build()
                )
            } else {
                @Suppress("DEPRECATION")
                setTaskDescription(
                    android.app.ActivityManager.TaskDescription("Auvy", iconRes)
                )
            }
        } catch (e: Exception) {
            // A recents card with the wrong icon is cosmetic; crashing over it is
            // not. Swallow and move on.
            android.util.Log.w("AuvyIcon", "task icon failed: ${e.message}")
        }
    }

    /**
     * onCreate IS TOO EARLY — RE-APPLY HERE.
     *
     * Setting the TaskDescription in onCreate looked right and did nothing: the
     * framework applies its OWN TaskDescription from the activity theme after
     * onCreate returns, which resets the icon. Proof from the device:
     *
     *   taskDescription { colorPrimary=#ff69f0ae iconRes=com.auvy.app/0 }
     *
     * colorPrimary set (the theme accent), iconRes ZERO — our icon overwritten.
     * onResume runs after that, so this is where the icon survives. Cheap: one
     * TaskDescription per resume, no allocation beyond the builder.
     */
    override fun onResume() {
        super.onResume()
        applyTaskIcon()
    }

    /**
     * THIRD PLACE THIS IS APPLIED, AND THE ONE THAT SHOULD STICK.
     *
     * onCreate and onResume both lost the race: the framework builds its OWN
     * TaskDescription from the activity theme as the window is attached, which
     * lands AFTER both and resets the icon. Measured on device after each attempt:
     *
     *   taskDescription { colorPrimary=#ff69f0ae iconRes=com.auvy.app/0 }
     *
     * colorPrimary set from the theme, iconRes zero. onWindowFocusChanged fires
     * after the window is attached and focused, so it is downstream of that write.
     * The delayed post is deliberate belt-and-braces for OEM shells that re-apply
     * their own description a frame later.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        applyTaskIcon()
        toastHandler.postDelayed({ applyTaskIcon() }, 400)
    }

    /**
     * Volume DOWN stops a ringing alarm, the way a clock app behaves.
     *
     * Reaching for the volume rocker is the reflex when a phone starts making
     * noise, and on an alarm it should silence it rather than quietly turn it down
     * — a half-volume alarm you then fall back asleep through is the worst
     * outcome. Only while AlarmAudioService is actually ringing; every other time
     * the volume keys behave normally, which is why this checks isRinging rather
     * than swallowing the key whenever the app is open.
     */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (AlarmAudioService.isRinging &&
            event.action == android.view.KeyEvent.ACTION_DOWN &&
            (event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN ||
                event.keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP)
        ) {
            android.util.Log.i("AuvyAlarm", "volume key stopped the alarm")
            AlarmAudioService.stop(applicationContext)
            // Tell Dart so the ringing screen closes and the lockscreen flags are
            // dropped — otherwise the audio stops and the screen sits there.
            try {
                alarmStoppedByKey?.invoke()
            } catch (_: Exception) {}
            return true // consumed: do not also change the volume
        }
        return super.dispatchKeyEvent(event)
    }

    /** Set by the alarm channel so a hardware key can close the Dart screen. */
    private var alarmStoppedByKey: (() -> Unit)? = null

    private fun applySecureFlag(enabled: Boolean) {
        try {
            if (enabled) {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
            }
        } catch (_: Exception) {
            // A window that refuses the flag must never take the app down with it.
        }
    }

    /**
     * Posts the "song found" receipt.
     *
     * Uses a DEFAULT-importance channel, not high: this is a confirmation of
     * something the user just asked for, not an interruption — it should appear
     * quietly and stay available, never buzz.
     */
    private fun showFoundNotification(title: String, artist: String) {
        try {
            val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
                    as android.app.NotificationManager
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                nm.createNotificationChannel(
                    android.app.NotificationChannel(
                        FOUND_CHANNEL,
                        "Identified songs",
                        android.app.NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
            val tapIntent = Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                // Space-joined, NOT nul-joined.
                //
                // This used a literal NUL as a field separator, but nothing ever
                // split it: consumeFoundTap returns the value whole and Dart hands
                // it straight to search() as a QUERY. So tapping the notification
                // searched for "title<NUL>artist" — a control character inside a
                // search string, which the API has no reason to honour.
                //
                // A space-joined "title artist" is exactly what a track search
                // wants, and it also keeps this file plain TEXT: the raw NUL made
                // every tool treat MainActivity.kt as a binary file.
                .putExtra(EXTRA_FOUND, "$title $artist")
            // The capture service's ID, NOT a second one.
            //
            // The in-app path shows "Listening…" then "Identifying…" on the
            // service's notification, and this used to answer on a DIFFERENT id —
            // so the shade briefly held two recognition notifications that
            // disagreed, and the progress one was left behind as litter. Posting
            // the answer over the same id makes the whole flow a single line that
            // advances in place, matching the headless path exactly.
            nm.cancel(FOUND_NOTIF_ID) // tidy up any answer left by an older build
            nm.notify(
                AudioCaptureService.RESULT_NOTIF_ID,
                android.app.Notification.Builder(this, FOUND_CHANNEL)
                    .setContentTitle(title)
                    .setContentText(
                        if (artist.isEmpty()) "Tap to open in Auvy"
                        else "$artist · Tap to open the album"
                    )
                    .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                    .setAutoCancel(true)
                    .setContentIntent(
                        android.app.PendingIntent.getActivity(
                            this,
                            // Distinct request code from the capture notification so
                            // one can't overwrite the other's PendingIntent.
                            1,
                            tapIntent,
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                                android.app.PendingIntent.FLAG_IMMUTABLE,
                        )
                    )
                    .build()
            )
        } catch (_: Exception) {
            // A failed receipt must never break a successful identification.
        }
    }


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer engine for stream playback. The ANDROID/IOS InnerTube
        // clients return pre-signed URLs, so no PoToken/BotGuard step is needed —
        // the old WebView PoToken generator (which never worked) has been removed.
        val playerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, playerChannelName)
        NativePlayerManager(context, playerChannel)

        // Cookie bridge: Android's CookieManager returns ALL cookies for a URL,
        // INCLUDING HttpOnly ones (SID, __Secure-3PSID, …) that the WebView's
        // document.cookie can't see. Those are the real auth cookies, so we read
        // them here to persist a YouTube login across restarts. (Replaces the
        // discontinued webview_cookie_manager plugin, which broke on modern
        // Flutter by referencing the removed v1-embedding Registrar.)
        val cookieChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, cookieChannelName)
        cookieChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getCookies" -> {
                    val url = call.argument<String>("url") ?: "https://music.youtube.com"
                    // "name=value; name2=value2" (all cookies, HttpOnly included), or null.
                    result.success(CookieManager.getInstance().getCookie(url))
                }
                // Opens the NATIVE sign-in screen (plain WebView — the setup
                // Google's login actually accepts; see LoginActivity). Resolves
                // true once music.youtube.com is reached with a session cookie.
                // The account picked in the native chooser at last sign-in.
                // NOT an identity — the Worker verifies that from the cookies.
                "lastLoginEmail" -> result.success(lastPickedEmail)
                "openLogin" -> {
                    if (pendingLoginResult != null) {
                        result.error("BUSY", "A sign-in is already in progress", null)
                    } else {
                        pendingLoginResult = result
                        val intent = Intent(this, LoginActivity::class.java)
                        // Device account picked natively (Dart side) → pre-fill
                        // the web flow's identifier step with it.
                        call.argument<String>("email")?.let {
                            if (it.isNotBlank()) intent.putExtra(LoginActivity.EXTRA_EMAIL_HINT, it)
                        }
                        startActivityForResult(intent, loginRequestCode)
                    }
                }
                // Opens the Discord sign-in WebView and resolves with the
                // account token (null if the user backs out). Used by the
                // Rich Presence gateway. See PresenceLoginActivity.
                "openPresenceLogin" -> {
                    if (pendingDiscordResult != null) {
                        result.error("BUSY", "A Discord sign-in is already in progress", null)
                    } else {
                        pendingDiscordResult = result
                        startActivityForResult(
                            Intent(this, PresenceLoginActivity::class.java),
                            discordRequestCode
                        )
                    }
                }
                // True when Auvy is already exempt from battery optimization.
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                // Prompt the system dialog to exempt Auvy from battery optimization
                // (keeps the network alive with the screen off on Samsung/One UI).
                // Returns true if already exempt (no dialog shown).
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        val pm = getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
                        if (pm.isIgnoringBatteryOptimizations(packageName)) {
                            result.success(true)
                        } else {
                            @Suppress("BatteryLife")
                            val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                                .setData(android.net.Uri.parse("package:$packageName"))
                            startActivity(intent)
                            result.success(false)
                        }
                    } catch (e: Exception) {
                        try {
                            startActivity(Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                        } catch (_: Exception) {}
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // (openLogin's result is delivered in onActivityResult below.)

        // Home-screen widget bridge: Dart pushes now-playing state ("update"),
        // the widget's LIKE button calls back ("toggleLike" via WidgetBridge).
        // Registered on the shared audio_service engine, so it stays wired
        // during background playback after the activity is destroyed.
        val widgetChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/widget")
        widgetChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    (call.arguments as? Map<*, *>)?.let {
                        WidgetBridge.handleUpdate(applicationContext, it)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        WidgetBridge.channel = widgetChannel

        // Native Android Toast — the app's single in-app message channel (the
        // old custom animated overlay was removed). Runs on the platform thread,
        // uses the application context so it survives activity transitions.
        val toastChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, toastChannelName)
        toastChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val msg = call.argument<String>("message") ?: ""
                    val long = call.argument<Boolean>("long") ?: false
                    if (msg.isNotBlank()) {
                        // Cancelled early, by design.
                        //
                        // These are quick acknowledgements — "Press back again to
                        // exit", "Backup complete", and Android LENGTH_SHORT holds
                        // them for about two seconds, which reads as the message
                        // hanging around long after it was understood. There is no
                        // arbitrary-duration Toast API, so the only way to get a
                        // brief one is to show a SHORT toast and cancel it.
                        //
                        // Always LENGTH_SHORT now: `long` selects a longer VISIBLE
                        // window below rather than a different Toast constant, so
                        // even a "long" message is well under the old default.
                        toastDismiss?.let { toastHandler.removeCallbacks(it) }
                        lastToast?.cancel()
                        val t = android.widget.Toast.makeText(
                            applicationContext, msg, android.widget.Toast.LENGTH_SHORT)
                        lastToast = t
                        t.show()
                        val visibleMs = if (long) 1800L else 1000L
                        val dismiss = Runnable {
                            t.cancel()
                            if (lastToast === t) lastToast = null
                        }
                        toastDismiss = dismiss
                        toastHandler.postDelayed(dismiss, visibleMs)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Wake-up alarm. Scheduling lives natively (AlarmManager survives Doze and
        // app death; a Dart Timer does not) — Dart only supplies the time/days and
        // asks, on startup, whether it was launched BY an alarm.
        // "Capture app audio" — recognise whatever another app is playing.
        //
        // Only launches the consent dialog; the capture itself lives in
        // AudioCaptureService because MediaProjection is only granted to a running
        // mediaProjection-typed foreground service on API 34+.
        val captureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/audiocapture"
        )
        // Tell Dart the instant a tile capture is ready, so it can identify and
        // replace the "Identifying…" notification with the real answer instead of
        // waiting for the user to open the app.
        // Reports back whether DART ANSWERED, so the service can fall back to the
        // headless engine when this listener is stale — it is never cleared, so its
        // mere existence proves nothing. See AudioCaptureService.onCaptureReady.
        AudioCaptureService.onCaptureReady = { ack ->
            runOnUiThread {
                try {
                    captureChannel.invokeMethod("pendingCaptureReady", null,
                        object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                // Dart returns true only once it has the capture in
                                // hand; anything else means it could not take it.
                                ack(result == true)
                            }

                            override fun error(code: String, msg: String?, details: Any?) {
                                Log.w("AuvyCapture", "handoff error: " + code)
                                ack(false)
                            }

                            override fun notImplemented() {
                                Log.w("AuvyCapture", "handoff not implemented in Dart")
                                ack(false)
                            }
                        })
                } catch (t: Exception) {
                    Log.w("AuvyCapture", "handoff invoke threw: " + t.message)
                    ack(false)
                }
            }
        }
        captureChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" ->
                    result.success(android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q)
                "isArmed" -> result.success(AudioCaptureService.isArmed)
                // Receipt for an identified track. Posted by Dart once recognition
                // succeeds, so the answer survives in the shade instead of living
                // only in a sheet the user may dismiss. Tapping it returns to Auvy
                // and opens the album.
                //
                // No engine, isolate or projection is retained by any of this — the
                // notification is a plain OS object and the tap is delivered as an
                // Intent extra.
                "notifyFound" -> {
                    val title = call.argument<String>("title") ?: ""
                    val artist = call.argument<String>("artist") ?: ""
                    if (title.isEmpty()) {
                        result.success(false)
                    } else {
                        showFoundNotification(title, artist)
                        result.success(true)
                    }
                }
                // Read-and-CLEAR: whether the user arrived here by tapping a
                // "found" notification. Cleared on read so a later resume can't
                // re-navigate to the same album.
                "consumeFoundTap" -> {
                    val v = pendingFoundTap
                    pendingFoundTap = null
                    result.success(v)
                }
                // Arm the quick-settings tile. Same consent dialog as a one-shot
                // capture, but the projection is RETAINED afterwards so no later
                // tile tap ever prompts again.
                "arm" -> {
                    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
                        result.error("UNSUPPORTED", "Needs Android 10 or newer", null)
                    } else if (AudioCaptureService.isArmed) {
                        result.success(true)
                    } else if (pendingCaptureResult != null) {
                        result.error("BUSY", "A capture request is already in progress", null)
                    } else {
                        pendingCaptureResult = result
                        pendingCaptureArm = true
                        try {
                            val mgr = getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE)
                                    as android.media.projection.MediaProjectionManager
                            startActivityForResult(
                                mgr.createScreenCaptureIntent(), captureRequestCode
                            )
                        } catch (e: Exception) {
                            pendingCaptureResult = null
                            pendingCaptureArm = false
                            result.error("NO_PROJECTION", e.message, null)
                        }
                    }
                }
                "disarm" -> {
                    startService(
                        Intent(this, AudioCaptureService::class.java)
                            .setAction(AudioCaptureService.ACTION_DISARM)
                    )
                    result.success(true)
                }
                "capture" -> {
                    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
                        result.error("UNSUPPORTED", "Needs Android 10 or newer", null)
                    } else if (pendingCaptureResult != null) {
                        result.error("BUSY", "A capture is already in progress", null)
                    } else {
                        pendingCaptureResult = result
                        pendingCaptureSeconds = call.argument<Double>("seconds") ?: 8.0
                        try {
                            val mgr = getSystemService(android.content.Context.MEDIA_PROJECTION_SERVICE)
                                    as android.media.projection.MediaProjectionManager
                            // Android shows its own scary screen-capture warning
                            // here. It cannot be suppressed or remembered — the
                            // system re-asks every session by design.
                            startActivityForResult(
                                mgr.createScreenCaptureIntent(), captureRequestCode
                            )
                        } catch (e: Exception) {
                            pendingCaptureResult = null
                            result.error("NO_PROJECTION", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Launcher-icon housekeeping, run on EVERY launch.
        //
        // Component enabled-state lives in the system's package settings and
        // survives app updates, so a device broken by the first version of this
        // feature (which disabled MainActivity — the aliases' own target) cannot be
        // fixed by shipping a corrected manifest alone. An app may always change
        // its own components, so this repairs it from the inside. Cheap and
        // idempotent when nothing is wrong.
        // `launchedAlias` is passed so a corrupt component set can never be
        // "repaired" by disabling the alias the user just launched from — that
        // would tear down the task and close the app on open.
        AlternateIconManager.repair(applicationContext, launchedAlias)

        // Alternative launcher icons. See AlternateIconManager for why the whole
        // component set is rewritten on every call.
        val iconChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/icon")
        iconChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setIcon" -> {
                    val variant = call.argument<String>("variant") ?: ""
                    if (!AlternateIconManager.isKnown(variant)) {
                        result.error("BAD_VARIANT", "Unknown icon variant: $variant", null)
                    } else {
                        val ok = AlternateIconManager.apply(applicationContext, variant)
                        // Update the recents card too. Dart writes the pref before
                        // calling this, so applyTaskIcon reads the new variant — and
                        // without it the task switcher kept the OLD icon until the
                        // next cold start, which is exactly the mismatch the
                        // launcher aliases were fixed for.
                        if (ok) applyTaskIcon(variant)
                        result.success(ok)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Open a folder in the user's file manager.
        //
        // Native because url_launcher can only fire a plain ACTION_VIEW, and on
        // this device Google's DocumentsUI claims that, which is how tapping the
        // folder button ended up in "Files" rather than Samsung's "My Files", the
        // app the user actually browses with.
        //
        // Order matters: OEM file managers advertise private intents that jump
        // straight to a path, which is what "open this folder" should mean.
        // Generic ACTION_VIEW is the fallback because the best it can do is open a
        // picker somewhere near the right place.
        // Backup files: write to Downloads, and open one the user picks
        // See the fields at the top of this class for why neither of these can be
        // done with a file path.
        val backupChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/backup")
        backupChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val name = call.argument<String>("name")
                    val bytes = call.argument<ByteArray>("bytes")
                    if (name == null || bytes == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 29) {
                            val values = android.content.ContentValues().apply {
                                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
                                // A generic type on purpose: this is not media, and
                                // claiming otherwise invites the media scanner to
                                // index it as a broken audio file.
                                put(
                                    android.provider.MediaStore.MediaColumns.MIME_TYPE,
                                    "application/octet-stream"
                                )
                                // Its own folder, so backups are together and easy
                                // to find rather than loose among every download.
                                put(
                                    android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                                    android.os.Environment.DIRECTORY_DOWNLOADS + "/Auvy"
                                )
                                put(android.provider.MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                            val collection =
                                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
                            val uri = contentResolver.insert(collection, values)
                            if (uri == null) {
                                result.success(null)
                                return@setMethodCallHandler
                            }
                            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                            // Cleared LAST: while IS_PENDING is set the file is
                            // invisible to other apps, which is what stops a
                            // half-written backup being read as a whole one.
                            values.clear()
                            values.put(android.provider.MediaStore.MediaColumns.IS_PENDING, 0)
                            contentResolver.update(uri, values, null, null)
                            result.success("Download/Auvy/$name")
                        } else {
                            // Pre-scoped-storage: the plain path still works, and
                            // WRITE_EXTERNAL_STORAGE is declared up to API 32.
                            val dir = java.io.File(
                                android.os.Environment.getExternalStoragePublicDirectory(
                                    android.os.Environment.DIRECTORY_DOWNLOADS
                                ),
                                "Auvy"
                            )
                            if (!dir.exists()) dir.mkdirs()
                            val file = java.io.File(dir, name)
                            file.writeBytes(bytes)
                            result.success("Download/Auvy/$name")
                        }
                    } catch (e: Exception) {
                        Log.w("AuvyBackup", "saveToDownloads failed: ${e.message}")
                        result.success(null)
                    }
                }

                "pickFile" -> {
                    if (pendingPickResult != null) {
                        // A picker is already open; a second call must not strand
                        // the first Dart future forever.
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            // Everything, because a .backup has no registered type
                            // and a filtered picker would grey out the very file
                            // the user came to choose. Auvy identifies the format
                            // by CONTENT once it has the bytes.
                            type = "*/*"
                        }
                        pendingPickResult = result
                        startActivityForResult(intent, pickFileRequestCode)
                    } catch (e: Exception) {
                        pendingPickResult = null
                        Log.w("AuvyBackup", "pickFile failed: ${e.message}")
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        val folderChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/folder")
        folderChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Tell the media store a file appeared.
                //
                // Writing into /Pictures does NOT make it visible: the gallery
                // indexes on a MediaScanner notification, and without one a saved
                // cover shows up whenever the system next happens to sweep —
                // which reads as "it did not save". One broadcast fixes it.
                // List audio in a public folder, without "all files access"
                //
                // THIS EXISTS TO DROP MANAGE_EXTERNAL_STORAGE. Importing tracks
                // the user copied into /Music/Auvy from another app used to call
                // `Directory.listSync()` on shared storage, which scoped storage
                // does not reliably permit, so the app requested "All files
                // access" to make it work.
                //
                // That permission was the single worst thing in the manifest: Play
                // requires a special declaration for it that music players do not
                // qualify for, and it is a strong malware heuristic because it
                // grants reach over every document and photo on the device. Auvy
                // needed exactly one thing from it — enumerating audio in one
                // folder, and MediaStore does that with READ_MEDIA_AUDIO alone.
                //
                // Queried by RELATIVE_PATH so it finds files whichever app wrote
                // them, which is the whole point of the feature.
                "listAudioIn" -> {
                    val rel = (call.argument<String>("relativePath") ?: "Music/Auvy/")
                        .trim('/') + "/"
                    val out = ArrayList<HashMap<String, Any?>>()
                    try {
                        val collection =
                            if (android.os.Build.VERSION.SDK_INT >= 29)
                                android.provider.MediaStore.Audio.Media.getContentUri(
                                    android.provider.MediaStore.VOLUME_EXTERNAL)
                            else
                                android.provider.MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        val cols = arrayOf(
                            android.provider.MediaStore.Audio.Media._ID,
                            android.provider.MediaStore.Audio.Media.DISPLAY_NAME,
                            android.provider.MediaStore.Audio.Media.DATA,
                            android.provider.MediaStore.Audio.Media.SIZE,
                            android.provider.MediaStore.Audio.Media.TITLE,
                            android.provider.MediaStore.Audio.Media.ARTIST,
                            android.provider.MediaStore.Audio.Media.ALBUM,
                            android.provider.MediaStore.Audio.Media.DURATION,
                        )
                        // RELATIVE_PATH only exists on Q+. Below that, filter on
                        // DATA (the real path), which is still readable there.
                        val (sel, args) = if (android.os.Build.VERSION.SDK_INT >= 29) {
                            "${android.provider.MediaStore.Audio.Media.RELATIVE_PATH} LIKE ?" to
                                arrayOf("$rel%")
                        } else {
                            "${android.provider.MediaStore.Audio.Media.DATA} LIKE ?" to
                                arrayOf("%/$rel%")
                        }
                        contentResolver.query(collection, cols, sel, args, null)?.use { c ->
                            val iId = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media._ID)
                            val iName = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DISPLAY_NAME)
                            val iData = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DATA)
                            val iSize = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.SIZE)
                            val iTitle = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.TITLE)
                            val iArtist = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ARTIST)
                            val iAlbum = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.ALBUM)
                            val iDur = c.getColumnIndexOrThrow(android.provider.MediaStore.Audio.Media.DURATION)
                            while (c.moveToNext()) {
                                val m = HashMap<String, Any?>()
                                m["id"] = c.getLong(iId)
                                m["name"] = c.getString(iName)
                                // The real file path, so the existing import and the
                                // player keep working on plain File paths. MediaStore
                                // returns it for media the caller may read.
                                m["path"] = c.getString(iData)
                                m["size"] = c.getLong(iSize)
                                m["title"] = c.getString(iTitle)
                                m["artist"] = c.getString(iArtist)
                                m["album"] = c.getString(iAlbum)
                                m["durationMs"] = c.getLong(iDur)
                                out.add(m)
                            }
                        }
                        result.success(out)
                    } catch (e: Exception) {
                        android.util.Log.w("AuvyFolder", "listAudioIn failed: ${e.message}")
                        // An empty list, not an error: "nothing to import" is the
                        // normal answer and the caller should not have to catch.
                        result.success(out)
                    }
                }
                "scanMedia" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (path.isEmpty()) {
                        result.success(false)
                    } else {
                        try {
                            android.media.MediaScannerConnection.scanFile(
                                applicationContext, arrayOf(path), null
                            ) { _, _ -> }
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                }
                "open" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(if (path.isEmpty()) false else openFolder(path))
                }
                else -> result.notImplemented()
            }
        }

        // Audio output switching
        //
        // Opens the SYSTEM output picker rather than a home-grown device list.
        // That is deliberate: the system dialog already enumerates Bluetooth,
        // wired, USB, HDMI and Cast targets, handles pairing and permissions, and
        // switches the route for the whole device. An in-app list could only ever
        // show a subset and could not actually move audio to a Cast receiver, so
        // it would look like a device chooser while quietly doing less.
        //
        // EXTRA_PACKAGE_NAME points the dialog at THIS app's media session, so it
        // opens showing where Auvy is playing instead of whatever session the
        // system considers most recent.
        outputChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/output")
        outputChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    // The media-output panel is API 29+. Below that, and on any
                    // ROM that ships without it, Bluetooth settings is the honest
                    // fallback — it is where the switch actually gets made.
                    val candidates = mutableListOf<Intent>()
                    if (android.os.Build.VERSION.SDK_INT >= 29) {
                        candidates.add(
                            Intent("android.settings.panel.action.MEDIA_OUTPUT")
                                .putExtra("android.intent.extra.PACKAGE_NAME", packageName)
                        )
                    }
                    candidates.add(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
                    candidates.add(Intent(android.provider.Settings.ACTION_SOUND_SETTINGS))
                    var opened = false
                    for (intent in candidates) {
                        try {
                            startActivity(intent)
                            opened = true
                            break
                        } catch (_: Exception) {
                            // Try the next one; a missing panel is not an error.
                        }
                    }
                    result.success(opened)
                }
                // The route audio is ACTUALLY on, so the button's icon is not a
                // guess. Returns null when it cannot be determined, and the Dart
                // side then shows a neutral icon rather than inventing a device.
                "route" -> result.success(currentAudioRoute())
                // True while the phone is driving a car display — Android Auto
                // projection, or a built-in automotive head unit. Needs no
                // permission, unlike inspecting Bluetooth device classes.
                "carMode" -> {
                    result.success(try {
                        val um = getSystemService(android.content.Context.UI_MODE_SERVICE)
                            as? android.app.UiModeManager
                        um?.currentModeType ==
                            android.content.res.Configuration.UI_MODE_TYPE_CAR
                    } catch (e: Exception) {
                        false
                    })
                }
                // Watches for outputs appearing and disappearing and tells Dart to
                // re-list, so a car or headset plugged in while the picker is open
                // shows up without the user reopening it.
                //
                // ON ONLY WHILE THE PICKER IS OPEN. A permanent callback would
                // stay alive all session to serve a sheet visible for seconds at a
                // time, waking work on every plug event that nothing is watching.
                //
                // AND IT LIVES ON THIS CHANNEL, NOT THE PLAYER'S. The Dart side
                // has to own a call handler to receive the push, and
                // native_audio_engine already owns the one on
                // com.auvy.app/native_player — taking it over would have silenced
                // position, state and track-end callbacks, i.e. broken playback.
                "watchOutputs" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    try {
                        val am = getSystemService(android.content.Context.AUDIO_SERVICE)
                            as android.media.AudioManager
                        outputWatcher?.let { am.unregisterAudioDeviceCallback(it) }
                        outputWatcher = null
                        if (enable) {
                            val cb = object : android.media.AudioDeviceCallback() {
                                override fun onAudioDevicesAdded(
                                    added: Array<out android.media.AudioDeviceInfo>?
                                ) {
                                    try { outputChannel.invokeMethod("outputsChanged", null) }
                                    catch (_: Exception) {}
                                }

                                override fun onAudioDevicesRemoved(
                                    removed: Array<out android.media.AudioDeviceInfo>?
                                ) {
                                    try { outputChannel.invokeMethod("outputsChanged", null) }
                                    catch (_: Exception) {}
                                }
                            }
                            am.registerAudioDeviceCallback(
                                cb,
                                android.os.Handler(android.os.Looper.getMainLooper()))
                            outputWatcher = cb
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Window-level privacy: FLAG_SECURE blocks screenshots, screen recording and
        // the recents-screen thumbnail. Kept on its own channel because it is a
        // property of THIS window, not of the player or the launcher.
        val windowChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/window")
        windowChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // THIS USED TO BE UNREACHABLE. It was registered on the TOAST
                // channel while Dart sent it to native_player, which does not
                // implement it, so every call came back notImplemented and the
                // caller's catch swallowed it. "Keep screen on" therefore did
                // nothing for as long as the setting has existed. It belongs here
                // next to setSecure: both are Activity WINDOW flags.
                "keepScreenOn" -> {
                    // Set on the ACTIVITY window, so it dies with the activity and
                    // can never leak into a background wake-lock.
                    val on = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (on) {
                            window.addFlags(
                                android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(
                                android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                    result.success(null)
                }
                "setSecure" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    // The pref is ALSO written here so onCreate can restore the flag
                    // on a later launch without waiting for Dart (see onCreate).
                    // Flutter's SharedPreferences namespaces every key with "flutter.".
                    try {
                        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
                            .edit().putBoolean("flutter.$SECURE_PREF_KEY", enabled).apply()
                    } catch (_: Exception) {}
                    applySecureFlag(enabled)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Where the user actually IS, for the "Auto" content region
        //
        // Dart derived Auto from `Platform.localeName`, which is the UI LANGUAGE's
        // country, not a location. A phone set to English (United States) reports
        // en_US no matter where it is, so "Auto" silently meant US for a huge share
        // of users — observed on the test device: persist.sys.locale = en-US while
        // the SIM country was `se`. The YouTube catalog, charts and release dates
        // then all came from the wrong country.
        //
        // Preference order, best signal first:
        //   1. SIM country     — where the account is registered. Stable, and does
        //                        not change when roaming.
        //   2. Network country — where the phone is attached right now. Covers
        //                        eSIM/no-SIM-ISO cases; wrong while roaming, which
        //                        is why it ranks below the SIM.
        //   3. null            — Dart falls back to the locale, the old behaviour.
        // No permission is needed for either country ISO.
        val regionChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/region")
        regionChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceRegion" -> {
                    var iso: String? = null
                    try {
                        val tm = getSystemService(android.content.Context.TELEPHONY_SERVICE)
                            as? android.telephony.TelephonyManager
                        iso = tm?.simCountryIso?.takeIf { it.length == 2 }
                            ?: tm?.networkCountryIso?.takeIf { it.length == 2 }
                    } catch (_: Exception) {}
                    result.success(iso?.uppercase())
                }
                else -> result.notImplemented()
            }
        }

        val alarmChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/alarm")
        // A hardware key can stop the alarm (see dispatchKeyEvent), and Dart owns
        // the screen that is showing, so native has to tell it, or the audio stops
        // and the ringing screen sits there with nothing behind it.
        alarmStoppedByKey = {
            runOnUiThread {
                try { alarmChannel.invokeMethod("alarmStoppedExternally", null) } catch (_: Exception) {}
            }
        }
        // Same signal, but for every OTHER way the alarm can end — the 15-minute
        // cap, the notification's Stop action, the system reclaiming the service.
        // Without it the audio stopped and the ringing screen stayed up.
        AlarmAudioService.onStoppedListener = { alarmStoppedByKey?.invoke() }
        alarmChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "schedule" -> {
                    val hour = call.argument<Int>("hour") ?: 7
                    val minute = call.argument<Int>("minute") ?: 30
                    val days = call.argument<List<Int>>("days") ?: emptyList()
                    AlarmScheduler.schedule(applicationContext, hour, minute, days.toSet())
                    result.success(true)
                }
                "cancel" -> {
                    AlarmScheduler.cancel(applicationContext)
                    result.success(true)
                }
                // The permission that decides whether the alarm screen appears.
                //
                // Android 14 restricted USE_FULL_SCREEN_INTENT to apps the store
                // classifies as alarm/calling apps; everyone else must be granted
                // it by the user. Declaring it in the manifest is not enough. When
                // it is refused, the alarm still RINGS (the service does that) but
                // the screen stays behind the lockscreen, so this has to be
                // visible in settings rather than failing quietly at 07:00.
                "canUseFullScreenIntent" -> {
                    var allowed = true
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 34) {
                            val nm = getSystemService(android.content.Context.NOTIFICATION_SERVICE)
                                as android.app.NotificationManager
                            allowed = nm.canUseFullScreenIntent()
                        }
                    } catch (_: Exception) {}
                    result.success(allowed)
                }
                "requestFullScreenIntent" -> {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 34) {
                            startActivity(Intent(
                                android.provider.Settings
                                    .ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                android.net.Uri.parse("package:$packageName")))
                        }
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "canScheduleExact" ->
                    result.success(AlarmScheduler.canScheduleExact(applicationContext))
                "requestExactPermission" -> {
                    // Android 12+ only: deep-link to the OS toggle. Without it the
                    // alarm still works, just batched by Doze (possibly minutes late).
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                        try {
                            startActivity(Intent(
                                android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                                android.net.Uri.parse("package:$packageName")))
                        } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                // Read-and-CLEAR: the flag must fire playback exactly once. Leaving
                // it set would restart the alarm music on the next resume.
                "consumePendingAlarm" -> {
                    val fired = alarmFired
                    alarmFired = false
                    result.success(fired)
                }
                // Handover from the native alarm
                //
                // The alarm is already playing by the time Dart is alive (see
                // AlarmAudioService). Dart asks what is ringing and how far in,
                // so it can continue THE SAME track at THE SAME position through
                // the normal pipeline instead of restarting it, and so there is
                // never a moment with two owners of the audio output.
                "alarmAudioState" -> result.success(AlarmAudioService.snapshot())
                "stopAlarmAudio" -> {
                    AlarmAudioService.stop(applicationContext)
                    result.success(true)
                }
                // The alarm screen is gone. Drop the lockscreen flags, and if the
                // ALARM is what opened Auvy, back out so the phone returns to
                // wherever it was — a clock app does not leave itself on screen
                // after you turn the alarm off, and being dumped into a music app
                // is one more thing to deal with before you are properly awake.
                "exitAlarmScreen" -> {
                    showOverLockscreen(false)
                    if (alarmLaunchedApp) {
                        alarmLaunchedApp = false
                        // moveTaskToBack, NOT finish(): the Flutter engine and the
                        // media session should survive — the app simply stops being
                        // frontmost, exactly as a dismissed alarm behaves.
                        try { moveTaskToBack(true) } catch (_: Exception) {}
                    }
                    result.success(true)
                }
                "snoozeAlarm" -> {
                    try {
                        applicationContext.startService(
                            Intent(applicationContext, AlarmAudioService::class.java)
                                .setAction(AlarmAudioService.ACTION_SNOOZE),
                        )
                    } catch (_: Exception) {}
                    result.success(true)
                }
                // A snooze you can call off
                //
                // Snooze was one-way: once tapped (often from the notification,
                // with the app not even running) the alarm WAS coming back and
                // nothing could stop it short of turning the whole alarm off. These
                // two exist because AlarmManager cannot be queried — the fire time
                // is recorded when the snooze is armed, and cross-checked here
                // against the live PendingIntent so the app never offers to cancel
                // something that isn't actually pending.
                "snoozeAt" ->
                    result.success(AlarmAudioService.snoozeAt(applicationContext))
                "cancelSnooze" ->
                    result.success(AlarmAudioService.cancelSnooze(applicationContext))
                else -> result.notImplemented()
            }
        }

        // Tell Dart an activity is now attached
        //
        // MUST BE LAST IN THIS METHOD. Dart reacts by re-testing the
        // native_player channel, so every channel above has to be registered
        // before this fires or the re-test fails and the app stays blank.
        //
        // Why it exists: this class extends AudioServiceActivity, which hands us
        // the engine audio_service ALREADY CACHED rather than a fresh one. So the
        // engine reaching this point may have booted headless (Bluetooth connect,
        // media button, QS tile, media-resumption probe) and already run main().
        // In that case main() found no native_player channel — correctly, it did
        // not exist yet — skipped runApp, and armed a listener here.
        //
        // Observed without this ping: the app opened to a permanent BLACK SCREEN
        // after being swiped away and relaunched from the media notification, and
        // a headset connect played nothing at all. Both because main() had already
        // returned in the engine the Activity then attached to.
        //
        // Harmless on a normal cold launch: main() has not run yet, so nothing is
        // listening, the message is dropped, and main()'s own check passes anyway.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "auvy/engine_lifecycle",
        ).invokeMethod("activityAttached", null)
    }

    /** Set when the activity was started by [AlarmReceiver]; consumed by Dart. */
    private var alarmFired = false

    /**
     * True when the ALARM is what started this Activity, as opposed to firing while
     * Auvy was already open. Decides whether dismissing the alarm screen backs out
     * of the app (clock-app behaviour) or leaves the user where they were.
     */
    private var alarmLaunchedApp = false

    /**
     * Show this Activity OVER THE LOCKSCREEN and wake the display.
     *
     * WITHOUT THIS THE ALARM SCREEN WAS INVISIBLE UNTIL THE PHONE WAS UNLOCKED,
     * which is the opposite of what an alarm is for — you hear music, you look at
     * the phone, and the screen that lets you stop it must already be there. The
     * full-screen intent asks the system to launch us; these two flags are what
     * let the launch actually appear on a locked, dark phone.
     *
     * Set PROGRAMMATICALLY and only for an alarm, never as a manifest attribute:
     * `android:showWhenLocked` would let the whole app — library, listening
     * history, everything — be read off a locked phone by anyone who picked it up.
     * Cleared again by [releaseLockscreen] as soon as the alarm is dismissed.
     */
    private fun showOverLockscreen(on: Boolean) {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(on)
                setTurnScreenOn(on)
            } else {
                @Suppress("DEPRECATION")
                val flags = android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                if (on) window.addFlags(flags) else window.clearFlags(flags)
            }
            // Keeps the display awake while the alarm screen is up, so it does not
            // time out mid-decision and drop back to the lockscreen.
            if (on) {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (e: Exception) {
            android.util.Log.w("AuvyAlarm", "lockscreen flags failed: ${e.message}")
        }
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Counted from onCreate, which runs the instant the Activity is created —
        // long before Dart is up. See [liveActivities] for why that timing matters.
        liveActivities++
        // Read the screenshot-blocking pref NATIVELY and apply it before the first
        // frame. Waiting for Dart would be too late twice over: the recents-screen
        // thumbnail is captured from the window as it stands, and a config change
        // recreates the Activity with a fresh window that Dart never re-applies to.
        applySecureFlag(readSecurePref())
        // The recents card is drawn from the task root, so this has to run here —
        // see applyTaskIcon.
        applyTaskIcon()
        // Opened by the quick-settings tile because the mic has never been granted.
        // A TileService cannot request a runtime permission, so the ask has to
        // happen here — otherwise the tile refuses forever and the user has no way
        // to fix it from the shade.
        if (intent?.getBooleanExtra(EXTRA_ASK_MIC, false) == true) {
            try {
                requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 4718)
            } catch (e: Exception) {
                android.util.Log.w("AuvyCapture", "mic request failed: ${e.message}")
            }
        }
        if (intent?.getBooleanExtra(AlarmScheduler.EXTRA_ALARM, false) == true) {
            alarmFired = true
            alarmLaunchedApp = true
            showOverLockscreen(true)
        }
        // Arrived by tapping a "song found" notification → Dart opens that album.
        intent?.getStringExtra(EXTRA_FOUND)?.let { pendingFoundTap = it }
    }

    /**
     * The component this task was launched from — the one alias that must NOT be
     * disabled while the task is alive. See AlternateIconManager.apply.
     */
    private val launchedAlias: String?
        get() = intent?.component?.className

    /**
     * Apply any pending launcher-icon change when the app is CLOSED FOR GOOD.
     *
     * Switching the icon means DISABLING the alias that is no longer wanted — and
     * that's normally the component the current task was launched from. Android
     * tears down a task whose root component gets disabled (DONT_KILL_APP spares
     * the process, not the task), so this can only be done at a moment where the
     * task going away is expected.
     *
     * THIS USED TO RUN IN onStop, AND onStop IS NOT THAT MOMENT. onStop fires
     * for any backgrounding — and the Google account picker takes the foreground
     * during sign-in, so on a fresh install the very first login pushed the app to
     * onStop, the pending swap disabled the alias the task was launched from, and
     * the app closed itself mid-login. Returning and retrying then "worked" only
     * because the swap had already happened, so there was nothing left to apply.
     *
     * isFinishing distinguishes "the user is done with this activity" from "it is
     * merely not visible"; isChangingConfigurations excludes a rotation/theme
     * recreate, which finishes the activity without the app going anywhere.
     */
    /**
     * Deliberately does NOT swap the launcher icon — the reasoning is in the body.
     *
     * THE DOC THAT USED TO SIT HERE DESCRIBED THE OPPOSITE. It explained why
     * onStop was "the earliest SAFE point" and claimed the new icon appears
     * immediately, which was behaviour (a) below — tried, shipped, and reverted
     * for producing duplicate launcher entries. The comment outlived the code and
     * contradicted the method it was attached to.
     */
    override fun onStop() {
        super.onStop()
        // DELIBERATELY DOES NOT SWAP THE ICON. Read this before "fixing" it.
        //
        // The obvious implementation — syncFromPrefs(ctx, launchedAlias) here —
        // was tried and REVERTED because it produces a visible bug: `protect`
        // spares the alias this task was launched from, so the new alias is
        // enabled while the old one stays enabled too. That is TWO launcher
        // entries, and the stale one is dead when tapped until the launcher
        // re-resolves it. Observed on device as "duplicates on my phone for a
        // while, and the duplicate isn't available when clicked".
        //
        // Dropping `protect` removes the duplicate but disables the component the
        // task was launched from, and Android removes a task whose root component
        // is disabled (DONT_KILL_APP spares the process, not the task). That
        // silently closes the app, and it is what broke sign-in, because
        // flutter_web_auth_2 backgrounds the app to show the browser, so onStop
        // fires mid-login.
        //
        // So there are three possible behaviours and no free one:
        //   a) protect at onStop      -> prompt icon, TEMPORARY DUPLICATE
        //   b) atomic swap at onStop  -> prompt icon, task vanishes from Recents,
        //                                and needs an OAuth-in-flight guard
        //   c) swap at onDestroy only -> no duplicate, but only lands when the
        //                                app actually finishes (current)
        //
        // (c) is in force. It is the honest default: nothing visibly wrong, at the
        // cost of the icon waiting for a real close. Picking between (b) and (c)
        // is a product call, not a technical one.
    }

    override fun onDestroy() {
        liveActivities = (liveActivities - 1).coerceAtLeast(0)
        if (isFinishing && !isChangingConfigurations) {
            // Unprotected on purpose: the task is going away anyway, so this is
            // where the alias onStop had to spare finally gets disabled.
            AlternateIconManager.syncFromPrefs(applicationContext)
        }
        // The early-dismiss Runnable captures this Activity (it touches lastToast),
        // so a pending one would hold it for up to its visible window after
        // destroy. Trivial in duration, but a posted callback outliving its
        // Activity is exactly the kind of thing that is invisible until it is not.
        toastDismiss?.let { toastHandler.removeCallbacks(it) }
        toastDismiss = null
        lastToast?.cancel()
        lastToast = null
        super.onDestroy()
    }

    // launchMode is singleTask, so an alarm arriving while Auvy is already open
    // comes through here rather than onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(AlarmScheduler.EXTRA_ALARM, false)) {
            alarmFired = true
            showOverLockscreen(true)
        }
        // Same reason: a notification tap while Auvy is already running arrives
        // HERE rather than in onCreate — the trap that made the second alarm
        // silently do nothing.
        intent.getStringExtra(EXTRA_FOUND)?.let { pendingFoundTap = it }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == loginRequestCode) {
            // Remember which account the chooser returned so Dart can pass it
            // to the Worker as a DISPLAY hint (see lastLoginEmail).
            if (resultCode == RESULT_OK) {
                lastPickedEmail = data?.getStringExtra(LoginActivity.EXTRA_PICKED_EMAIL)
            }
            pendingLoginResult?.success(resultCode == RESULT_OK)
            pendingLoginResult = null
            return
        }
        if (requestCode == discordRequestCode) {
            val token = if (resultCode == RESULT_OK)
                data?.getStringExtra(PresenceLoginActivity.EXTRA_TOKEN) else null
            pendingDiscordResult?.success(token)
            pendingDiscordResult = null
            return
        }
        if (requestCode == pickFileRequestCode) {
            val pending = pendingPickResult
            pendingPickResult = null
            if (pending == null) return
            val uri = if (resultCode == RESULT_OK) data?.data else null
            if (uri == null) {
                pending.success(null) // cancelled — not an error
                return
            }
            try {
                // Copied into the cache so Dart works with a real File, exactly as
                // it does for a path-based backup. The SAF grant does not survive
                // the process, and a backup import must not depend on it doing so.
                var name = "picked.backup"
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) {
                        c.getString(idx)?.let { name = it }
                    }
                }
                val out = java.io.File(cacheDir, "picked_backup_${System.currentTimeMillis()}")
                contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                } ?: run {
                    pending.success(null)
                    return
                }
                pending.success(mapOf("path" to out.absolutePath, "name" to name))
            } catch (e: Exception) {
                Log.w("AuvyBackup", "reading picked file failed: ${e.message}")
                pending.success(null)
            }
            return
        }
        if (requestCode == captureRequestCode) {
            val pending = pendingCaptureResult
            val arming = pendingCaptureArm
            pendingCaptureResult = null
            pendingCaptureArm = false
            if (pending == null) return
            if (arming) {
                if (resultCode != RESULT_OK || data == null) {
                    pending.error("DENIED", "Screen capture permission declined", null)
                    return
                }
                // Retains the projection; no result callback — the tile writes its
                // captures to a file for Dart to pick up later instead.
                try {
                    startForegroundService(
                        Intent(this, AudioCaptureService::class.java)
                            .setAction(AudioCaptureService.ACTION_ARM)
                            .putExtra(AudioCaptureService.EXTRA_RESULT_CODE, resultCode)
                            .putExtra(AudioCaptureService.EXTRA_RESULT_DATA, data)
                    )
                    pending.success(true)
                } catch (e: Exception) {
                    pending.error("SERVICE_FAILED", e.message, null)
                }
                return
            }
            if (resultCode != RESULT_OK || data == null) {
                // Declining the system dialog is a normal choice, not a fault —
                // a distinct code so the UI can say "permission needed" rather
                // than "something went wrong".
                pending.error("DENIED", "Screen capture permission declined", null)
                return
            }
            // The service delivers PCM (or null) through this callback, then stops
            // itself. Set BEFORE starting it so the result can't be missed.
            AudioCaptureService.onResult = { bytes ->
                if (bytes == null) {
                    pending.error(
                        "NO_AUDIO",
                        "No capturable audio was playing. Some apps block capture.",
                        null,
                    )
                } else {
                    pending.success(bytes)
                }
            }
            val svc = Intent(this, AudioCaptureService::class.java).apply {
                putExtra(AudioCaptureService.EXTRA_RESULT_CODE, resultCode)
                putExtra(AudioCaptureService.EXTRA_RESULT_DATA, data)
                putExtra(AudioCaptureService.EXTRA_SECONDS, pendingCaptureSeconds)
            }
            try {
                startForegroundService(svc)
            } catch (e: Exception) {
                AudioCaptureService.onResult = null
                pending.error("SERVICE_FAILED", e.message, null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
