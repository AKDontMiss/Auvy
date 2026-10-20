package com.auvy.app

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.util.Log
import com.auvy.enginehook.EngineHost
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The app's own code on every Flutter engine, not only the one MainActivity
 * shows.
 *
 * audio_service runs main() in an engine of its own whenever its service starts
 * without a screen: Android Auto connecting, a headset button, a widget, the
 * system's media check. MainActivity's channels, the native player among them,
 * arrive only when a screen opens, so main() waits for one (see main.dart). That
 * left Android Auto with a spinner whenever Auvy wasn't open on the phone: the
 * car's requests queue in audio_service until the app registers its handler.
 *
 * AuvyEngineHook (packages/auvy_engine_hook) reports each engine here, and each
 * gets the `auvy/engine` channel:
 * - `carConnected`: whether Android Auto is projecting now. Only then does the
 *   app start without a screen; every other background start still waits.
 * - `attachPlayer`: the native player on this engine. MainActivity adds one again
 *   when a screen opens; the player itself is shared and the newest channel wins.
 * - `installMediaKeys`: see [LiteralMediaKeys].
 * An engine already waiting when the car connects is told so (`carConnected` on
 * `auvy/engine_lifecycle`).
 */
class AuvyApplication : Application(), EngineHost {

    /** Engines alive in this process. Main thread only. */
    private val engines = mutableSetOf<BinaryMessenger>()

    override fun onCreate() {
        super.onCreate()
        watchCarConnection()
    }

    override fun onEngineAttached(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        engines.add(messenger)
        var player: NativePlayerManager? = null
        MethodChannel(messenger, ENGINE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "carConnected" -> result.success(isCarConnected())
                "attachPlayer" -> {
                    if (player == null) {
                        player = NativePlayerManager(this, MethodChannel(messenger, PLAYER_CHANNEL))
                    }
                    result.success(true)
                }
                "installMediaKeys" -> result.success(LiteralMediaKeys.install())
                else -> result.notImplemented()
            }
        }
    }

    override fun onEngineDetached(binding: FlutterPlugin.FlutterPluginBinding) {
        engines.remove(binding.binaryMessenger)
        MethodChannel(binding.binaryMessenger, ENGINE_CHANNEL).setMethodCallHandler(null)
    }

    /**
     * Whether Android Auto is projecting, read the way androidx.car.app's
     * CarConnection reads it: from the car host's provider (2 = projection).
     * The manifest's <queries> makes the provider visible on Android 11+.
     */
    private fun isCarConnected(): Boolean = try {
        contentResolver.query(CAR_CONNECTION_URI, arrayOf(CAR_CONNECTION_STATE), null, null, null)
            ?.use { c -> c.moveToFirst() && c.getInt(c.getColumnIndexOrThrow(CAR_CONNECTION_STATE)) == 2 }
            ?: false
    } catch (e: Exception) {
        // No car host installed, or it refused: not connected.
        false
    }

    /** Tells waiting engines when Android Auto connects. Once per process. */
    private fun watchCarConnection() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (!isCarConnected()) return
                Log.i(TAG, "Android Auto connected; telling ${engines.size} engine(s)")
                for (messenger in engines.toList()) {
                    MethodChannel(messenger, LIFECYCLE_CHANNEL).invokeMethod("carConnected", null)
                }
            }
        }
        val filter = IntentFilter(ACTION_CAR_CONNECTION_UPDATED)
        try {
            // Sent by the car host, another app, so the receiver is exported.
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
        } catch (e: Exception) {
            Log.w(TAG, "car connection watch unavailable: $e")
        }
    }

    private companion object {
        const val TAG = "AuvyApplication"
        const val ENGINE_CHANNEL = "auvy/engine"
        const val LIFECYCLE_CHANNEL = "auvy/engine_lifecycle"
        const val PLAYER_CHANNEL = "com.auvy.app/native_player"
        val CAR_CONNECTION_URI: Uri = Uri.parse("content://androidx.car.app.connection")
        const val CAR_CONNECTION_STATE = "CarConnectionState"
        const val ACTION_CAR_CONNECTION_UPDATED = "androidx.car.app.connection.action.CAR_CONNECTION_UPDATED"
    }
}
