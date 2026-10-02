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
    private val captureRequestCode = 4715

    /// "title artist" when the activity was opened by tapping a "song found"
    /// notification, so Dart can jump straight to that album. Read-and-cleared.
    private var pendingFoundTap: String? = null

    /// Set when a What's New notification opened the activity. Read-and-cleared
    /// by Dart (consumeOpen); [whatsNewChannel] tells a running Dart at once.
    private var pendingWhatsNewTap = false
    private var whatsNewChannel: MethodChannel? = null

    // Backup files, without "all files access".
    //
    // Auvy holds no MANAGE_EXTERNAL_STORAGE (see the manifest), so under scoped
    // storage Dart's File API can't write a .backup into /Download or list
    // backups other apps put there. Both are handled without extra permissions:
    //
    //   saveToDownloads  → MediaStore's Downloads collection (any app may insert
    //                      there on API 29+); the file shows in Files under
    //                      Download/Auvy.
    //   pickFile         → a system file picker. Choosing the file is the grant,
    //                      so it works for another app's backup anywhere on the
    //                      device or in cloud storage.
    private var pendingPickResult: MethodChannel.Result? = null
    private val pickFileRequestCode = 4717

    companion object {
        /// Internal, but NOT private: AudioCaptureService attaches it too, so a
        /// match found headlessly opens the album on tap exactly like an in-app
        /// one. See notifyResult there.
        const val EXTRA_FOUND = "auvy_found_track"

        /// How many MainActivity instances exist right now.
        ///
        /// AudioCaptureService retires its process after headless work and must not
        /// do so while the app is on screen. Process importance can't answer that (a
        /// foreground service makes the process look visible), so this counter is
        /// used instead. Incremented in onCreate, before Dart starts.
        @Volatile
        @JvmStatic
        var liveActivities = 0
        private const val FOUND_CHANNEL = "auvy_found"
        private const val FOUND_NOTIF_ID = 8810

        /** Dart-side key, without Flutter's "flutter." SharedPreferences prefix. */
        private const val SECURE_PREF_KEY = "auvy_block_screenshots"
    }

    private lateinit var outputChannel: MethodChannel

    /// Registered only while the output picker is open. See "watchOutputs".
    private var outputWatcher: android.media.AudioDeviceCallback? = null

    /**
     * Which output media audio is going to: "bluetooth", "headphones", "usb",
     * "hdmi", "speaker", or null when nothing can be said.
     *
     * Android doesn't expose the actual media route to ordinary apps
     * (`getDevicesForAttributes` is a system API; `getCommunicationDevice` is
     * the call route), so this picks the highest-priority connected output in
     * the order the platform uses: Bluetooth, USB, wired, HDMI, speaker. It's
     * only used to choose which icon to draw; nothing is routed from here.
     */
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

    /**
     * Opens [path] in a file manager, preferring the device's own.
     *
     * Android has no public "reveal this directory" API, so this tries, in order:
     *
     * 1. **Samsung My Files**: `samsung.myfiles.intent.action.LAUNCH_MY_FILES`
     *    with a `START_PATH` extra (undocumented but stable across One UI).
     * 2. **DocumentsUI tree URI**: opens Google Files at the folder.
     * 3. **Generic ACTION_VIEW** on a `file://` URI with a folder MIME type,
     *    for third-party managers that still handle it.
     *
     * Each attempt is wrapped so a file manager rejecting the intent can't crash
     * the app.
     */
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
     * Put the chosen icon variant on the recents/task-switcher card.
     *
     * Launcher aliases only change the launcher entry; the recents card takes its
     * icon from the task's root activity (MainActivity), which inherits the stock
     * application icon. TaskDescription sets it at runtime, since the manifest
     * can't know which variant is active.
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
     * Re-applied in onResume: the framework applies its own TaskDescription
     * from the theme after onCreate returns, which resets the icon.
     */
    override fun onResume() {
        super.onResume()
        applyTaskIcon()
    }

    /**
     * Re-applied once more when the window gains focus, which happens after
     * the framework's own TaskDescription is written as the window attaches. The
     * delayed post covers OEM shells that re-apply theirs a frame later.
     */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus) return
        applyTaskIcon()
        toastHandler.postDelayed({ applyTaskIcon() }, 400)
    }

    /**
     * Volume DOWN stops a ringing alarm, like a clock app. Only while
     * AlarmAudioService is actually ringing; otherwise the volume keys behave
     * normally.
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
                // Joined with a space: Dart passes this straight to search() as a query, so
                // "title artist" is exactly what a track search wants.
                .putExtra(EXTRA_FOUND, "$title $artist")
            // Posts the answer on the capture service's notification id, so the
            // "Listening…" → "Identifying…" → result flow is one notification that
            // updates in place (same as the headless path).
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

    private fun performNativeHaptic(type: String) {
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(android.content.Context.VIBRATOR_MANAGER_SERVICE) as? android.os.VibratorManager
                val vibrator = vibratorManager?.defaultVibrator
                if (vibrator != null && vibrator.hasVibrator()) {
                    val effectId = when (type) {
                        "selection" -> android.os.VibrationEffect.EFFECT_TICK
                        "light" -> android.os.VibrationEffect.EFFECT_CLICK
                        "medium" -> android.os.VibrationEffect.EFFECT_CLICK
                        "heavy" -> android.os.VibrationEffect.EFFECT_HEAVY_CLICK
                        else -> android.os.VibrationEffect.EFFECT_CLICK
                    }
                    vibrator.vibrate(android.os.VibrationEffect.createPredefined(effectId))
                    return
                }
            } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator
                if (vibrator != null && vibrator.hasVibrator()) {
                    val effectId = when (type) {
                        "selection" -> android.os.VibrationEffect.EFFECT_TICK
                        "light" -> android.os.VibrationEffect.EFFECT_CLICK
                        "medium" -> android.os.VibrationEffect.EFFECT_CLICK
                        "heavy" -> android.os.VibrationEffect.EFFECT_HEAVY_CLICK
                        else -> android.os.VibrationEffect.EFFECT_CLICK
                    }
                    vibrator.vibrate(android.os.VibrationEffect.createPredefined(effectId))
                    return
                }
            } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(android.content.Context.VIBRATOR_SERVICE) as? android.os.Vibrator
                val ms = when (type) {
                    "selection" -> 15L
                    "light" -> 25L
                    "medium" -> 40L
                    "heavy" -> 60L
                    else -> 25L
                }
                vibrator?.vibrate(android.os.VibrationEffect.createOneShot(ms, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
                return
            }
        } catch (_: Exception) {}

        try {
            window?.decorView?.let { view ->
                val constant = when (type) {
                    "selection" -> android.view.HapticFeedbackConstants.CLOCK_TICK
                    "light" -> android.view.HapticFeedbackConstants.KEYBOARD_TAP
                    "medium" -> android.view.HapticFeedbackConstants.VIRTUAL_KEY
                    "heavy" -> android.view.HapticFeedbackConstants.LONG_PRESS
                    else -> android.view.HapticFeedbackConstants.KEYBOARD_TAP
                }
                view.performHapticFeedback(constant, android.view.HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING)
            }
        } catch (_: Exception) {}
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Native ExoPlayer engine for stream playback. The ANDROID/IOS InnerTube
        // clients return pre-signed URLs, so no PoToken/BotGuard step is needed.
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

        // Native Android Toast, the app's single in-app message channel. Runs on
        // the platform thread and uses the application context so it survives
        // activity transitions.
        val toastChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, toastChannelName)
        toastChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val msg = call.argument<String>("message") ?: ""
                    val long = call.argument<Boolean>("long") ?: false
                    if (msg.isNotBlank()) {
                        // Toasts are cut short on purpose: there's no arbitrary-duration Toast API,
                        // and LENGTH_SHORT (~2s) lingers for quick acknowledgements like "Press back
                        // again to exit". So a SHORT toast is shown and cancelled after a shorter
                        // visible window (`long` just picks a longer window).
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

        // Native Haptic channel: triggers VibratorManager / Vibrator with predefined tactile clicks
        val hapticsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/haptics")
        hapticsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "vibrate" -> {
                    val type = call.argument<String>("type") ?: "light"
                    performNativeHaptic(type)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // "Capture app audio": recognise whatever another app is playing.
        //
        // This only launches the consent dialog; the capture itself lives in
        // AudioCaptureService, because on API 34+ MediaProjection is only granted to
        // a running mediaProjection-typed foreground service.
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
                // Notification for an identified track, posted by Dart once recognition
                // succeeds so the answer stays in the shade even if the sheet is dismissed.
                // Tapping it returns to Auvy and opens the album. Nothing is retained
                // natively; the tap arrives as an Intent extra.
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

        // Launcher-icon housekeeping on every launch: repairs a broken component
        // state (it survives app updates). `launchedAlias` is protected so a repair
        // can never disable the alias the user just launched from, which would close
        // the app.
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
                        val ok = AlternateIconManager.apply(applicationContext, variant, launchedAlias)
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

        // Backup files: write to Downloads, and open one the user picks. See the
        // fields at the top of this class for why neither can use a file path.
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
                        // Prefer the phone's own file manager, as openFolder does: an
                        // ACTION_OPEN_DOCUMENT picker is always DocumentsUI, while OEM managers
                        // (e.g. Samsung My Files) register for ACTION_GET_CONTENT. The URI comes back
                        // without persistable permission, which is fine because it's read at once
                        // and never stored.
                        val picker = Intent(Intent.ACTION_GET_CONTENT)
                            .setPackage("com.sec.android.app.myfiles")
                            .apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            .takeIf { it.resolveActivity(packageManager) != null }
                            ?: Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                // Everything, because a .backup has no registered
                                // type and a filtered picker would grey out the
                                // very file the user came to choose. Auvy
                                // identifies the format by CONTENT once it has the
                                // bytes.
                                type = "*/*"
                            }
                        pendingPickResult = result
                        startActivityForResult(picker, pickFileRequestCode)
                    } catch (e: Exception) {
                        pendingPickResult = null
                        Log.w("AuvyBackup", "pickFile failed: ${e.message}")
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // Open a folder in the user's file manager. Native because url_launcher
        // can only fire a plain ACTION_VIEW, which Google's DocumentsUI tends to
        // claim; OEM file managers offer intents that jump straight to a path.
        val folderChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/folder")
        folderChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // List audio in a public folder, without "all files access".
                //
                // Importing tracks the user copied into /Music/Auvy used to need
                // MANAGE_EXTERNAL_STORAGE to list shared storage. MediaStore does it with
                // READ_MEDIA_AUDIO alone. Queried by RELATIVE_PATH so it finds files
                // whichever app wrote them.
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
                // Tell the media store a file appeared, so a saved cover shows up in
                // the gallery right away instead of at the next system scan.
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

        // Audio output switching.
        //
        // Opens the system output picker rather than an in-app device list: it
        // already lists Bluetooth, wired, USB, HDMI and Cast targets, handles pairing
        // and actually moves the route. EXTRA_PACKAGE_NAME opens it on this app's
        // media session.
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
                // Watches for outputs appearing and disappearing and tells Dart to re-list,
                // so a device connected while the picker is open shows up.
                //
                // Only registered while the picker is open. It lives on this channel rather
                // than the player's, because native_audio_engine already owns the call
                // handler on com.auvy.app/native_player.
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
                // Belongs on this channel next to setSecure: both are Activity window flags.
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

        // The user's country for the "Auto" content region.
        //
        // The UI locale's country isn't a location (an en_US phone reports US
        // anywhere), so this prefers:
        //   1. SIM country: where the account is registered; stable when roaming.
        //   2. Network country: covers eSIM/no-SIM cases; wrong while roaming.
        //   3. null: Dart falls back to the locale.
        // Neither needs a permission.
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

        // Wake-up alarm. Scheduling is native (AlarmManager survives Doze and app
        // death; a Dart Timer doesn't). Dart supplies the time/days and asks on
        // startup whether it was launched by an alarm.
        // What's New: notifications for what a check in the app found, the closed-app
        // job (WhatsNewJobService), and the tap that opens the page. The permission
        // itself is asked through permission_handler in Dart.
        whatsNewChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/whatsnew")
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "permission" -> {
                            val nm = getSystemService(android.app.NotificationManager::class.java)
                            result.success(if (nm?.areNotificationsEnabled() == true) "granted" else "denied")
                        }
                        "notify" -> {
                            val items = call.argument<List<Map<String, Any?>>>("items") ?: emptyList()
                            for (item in items) {
                                val id = item["id"] as? String ?: continue
                                WhatsNewJobService.post(applicationContext, id,
                                    item["title"] as? String ?: continue, item["body"] as? String ?: "")
                            }
                            result.success(null)
                        }
                        "setBackground" -> {
                            val on = call.argument<Boolean>("enabled") ?: false
                            // Data saver keeps the closed-app check to unmetered networks.
                            val saver = call.argument<Boolean>("dataSaver") ?: false
                            WhatsNewJobService.setEnabled(applicationContext, on, saver)
                            result.success(null)
                        }
                        "consumeOpen" -> {
                            val v = pendingWhatsNewTap
                            pendingWhatsNewTap = false
                            result.success(v)
                        }
                        "openSettings" -> {
                            startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }

        // WebP encoding for custom covers (see artwork_override_provider). Off the main
        // thread: decoding and compressing a picked photo takes a moment.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.auvy.app/image")
            .setMethodCallHandler { call, result ->
                if (call.method != "encodeWebp") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val bytes = call.argument<ByteArray>("bytes")
                val maxDim = call.argument<Int>("maxDimension") ?: 384
                val quality = call.argument<Int>("quality") ?: 82
                if (bytes == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                Thread {
                    val out = try {
                        encodeWebp(bytes, maxDim, quality)
                    } catch (_: Exception) {
                        null
                    }
                    runOnUiThread { result.success(out) }
                }.start()
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
                // Whether the alarm screen can appear over the lockscreen. Since Android 14,
                // USE_FULL_SCREEN_INTENT must be granted by the user for most apps. Without
                // it the alarm still rings (the service does that) but the screen stays
                // behind the lockscreen, so settings shows this state.
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
                // Handover from the native alarm: it is already playing by the time Dart
                // starts (see AlarmAudioService). Dart asks what is ringing and how far in,
                // so it can continue the same track at the same position through the normal
                // player, with only one audio owner at a time.
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
                // Snooze status and cancel. AlarmManager can't be queried, so the fire time
                // is recorded when the snooze is armed and cross-checked against the live
                // PendingIntent, so the app never offers to cancel something that isn't
                // pending.
                "snoozeAt" ->
                    result.success(AlarmAudioService.snoozeAt(applicationContext))
                "cancelSnooze" ->
                    result.success(AlarmAudioService.cancelSnooze(applicationContext))
                else -> result.notImplemented()
            }
        }

        // Tell Dart an activity is now attached.
        //
        // Must stay LAST in this method: Dart reacts by re-testing the native_player
        // channel, so every channel above must already be registered.
        //
        // This class extends AudioServiceActivity, which reuses the engine
        // audio_service already cached. That engine may have started headless
        // (Bluetooth connect, media button, QS tile, media resumption) and already
        // run main(), which found no native_player channel, skipped runApp, and is
        // waiting for this ping. On a normal cold launch nothing is listening yet
        // and the message is simply dropped.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "auvy/engine_lifecycle",
        ).invokeMethod("activityAttached", null)
    }

    /** A picture as WebP, its longest side at most [maxDim]. */
    private fun encodeWebp(bytes: ByteArray, maxDim: Int, quality: Int): ByteArray? {
        val src = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
        val longest = maxOf(src.width, src.height)
        val bitmap = if (longest > maxDim) {
            val scale = maxDim.toFloat() / longest
            android.graphics.Bitmap.createScaledBitmap(
                src, (src.width * scale).toInt().coerceAtLeast(1),
                (src.height * scale).toInt().coerceAtLeast(1), true)
        } else src
        val format = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            android.graphics.Bitmap.CompressFormat.WEBP_LOSSY
        } else {
            @Suppress("DEPRECATION") android.graphics.Bitmap.CompressFormat.WEBP
        }
        val out = java.io.ByteArrayOutputStream()
        if (!bitmap.compress(format, quality, out)) return null
        if (bitmap !== src) bitmap.recycle()
        src.recycle()
        return out.toByteArray()
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
     * Show this Activity over the lockscreen and turn the screen on, so the
     * alarm screen is visible on a locked, dark phone.
     *
     * Set in code and only for an alarm, never as a manifest attribute, which
     * would expose the whole app on a locked phone. Cleared again by
     * [releaseLockscreen] once the alarm is dismissed.
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
        if (intent?.getBooleanExtra(AlarmScheduler.EXTRA_ALARM, false) == true) {
            alarmFired = true
            alarmLaunchedApp = true
            showOverLockscreen(true)
        }
        // Arrived by tapping a "song found" notification → Dart opens that album.
        intent?.getStringExtra(EXTRA_FOUND)?.let { pendingFoundTap = it }
        if (intent?.getBooleanExtra(WhatsNewJobService.EXTRA_OPEN, false) == true) {
            pendingWhatsNewTap = true
        }
    }

    /**
     * The component this task was launched from — the one alias that must NOT be
     * disabled while the task is alive. See AlternateIconManager.apply.
     */
    private val launchedAlias: String?
        get() = intent?.component?.className

    /**
     * Deliberately does not swap the launcher icon; see the note in the body.
     */
    override fun onStop() {
        super.onStop()
        // Icon swaps don't happen here. Dart applies a new icon immediately through
        // the `setIcon` channel with `launchedAlias` protected, so the alias this
        // task was launched from stays enabled (a temporary second launcher entry)
        // until onDestroy runs when the app is closed for good.
        //
        // Disabling that alias here instead would close the app: Android removes a
        // task whose root component is disabled (DONT_KILL_APP spares the process,
        // not the task), and onStop also fires mid sign-in while the browser is in
        // front.
    }

    /**
     * Applies any pending launcher-icon change when the app is closed for good.
     *
     * Switching disables the alias the current task was launched from, and
     * Android tears down a task whose root component is disabled, so this only
     * runs when the task is going away anyway. isFinishing means the user is
     * done with the activity; isChangingConfigurations excludes a rotation or
     * theme recreate.
     */
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
        if (intent.getBooleanExtra(WhatsNewJobService.EXTRA_OPEN, false)) {
            pendingWhatsNewTap = true
            try { whatsNewChannel?.invokeMethod("openWhatsNew", null) } catch (_: Exception) {}
        }
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
            pendingCaptureResult = null
            if (pending == null) return
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
