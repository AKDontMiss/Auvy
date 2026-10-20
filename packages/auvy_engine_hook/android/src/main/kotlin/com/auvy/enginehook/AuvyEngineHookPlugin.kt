package com.auvy.enginehook

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Implemented by the app's Application to hear about every Flutter engine.
 *
 * An Activity's configureFlutterEngine runs only for the engine it shows.
 * audio_service also starts an engine of its own whenever its service starts
 * without a screen (Android Auto connecting, a headset button, a widget), and
 * plugins are the only code Flutter attaches to every engine. So this plugin
 * hands each one to the app.
 */
interface EngineHost {
    fun onEngineAttached(binding: FlutterPlugin.FlutterPluginBinding)
    fun onEngineDetached(binding: FlutterPlugin.FlutterPluginBinding)
}

class AuvyEngineHookPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        (binding.applicationContext as? EngineHost)?.onEngineAttached(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        (binding.applicationContext as? EngineHost)?.onEngineDetached(binding)
    }
}
