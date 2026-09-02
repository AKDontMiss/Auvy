package com.auvy.app

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Switches the launcher icon between the aliases declared in AndroidManifest.xml.
 *
 * Android has no "set icon" API: each icon is a separate launcher component, and
 * you enable the one you want. Two hard rules follow, and breaking either one
 * makes the app unreachable from the home screen:
 *
 *  1. **Exactly one alias enabled.** Two → the app appears twice in the launcher.
 *     Zero → it disappears with no way back in. So [apply] always rewrites the
 *     whole set rather than toggling one component in isolation.
 *
 *  2. **Never disable [TARGET].** MainActivity is the `targetActivity` of every
 *     alias. The first version of this feature treated MainActivity as the
 *     "default icon" launcher entry, so picking a colour disabled it — which
 *     killed the existing home-screen entry and made Android report
 *     *"app is unavailable"*. The default icon is now its own alias
 *     ([DEFAULT_ALIAS]) and MainActivity is never passed to
 *     setComponentEnabledSetting at all, except by [repair] to switch it back on.
 */
object AlternateIconManager {

    /** The real activity every alias points at. Must always stay enabled. */
    private const val TARGET = "com.auvy.app.MainActivity"

    /** Launcher entry for the stock icon. */
    private const val DEFAULT_ALIAS = "com.auvy.app.MainActivityDefault"

    /** Variant key → alias component. `""` is the stock icon. */
    private val aliases = mapOf(
        "" to DEFAULT_ALIAS,
        "green" to "com.auvy.app.MainActivityGreen",
        "orange" to "com.auvy.app.MainActivityOrange",
        "pink" to "com.auvy.app.MainActivityPink",
        "purple" to "com.auvy.app.MainActivityPurple",
        "red" to "com.auvy.app.MainActivityRed",
    )

    fun isKnown(variant: String) = aliases.containsKey(variant)

    /**
     * Undo the damage done by the first version of this feature, and by any
     * partially-applied switch.
     *
     * Component enabled-state is stored in the system's package settings and
     * SURVIVES an app update, so shipping a corrected manifest is not enough on
     * its own — a device where MainActivity was already disabled would stay
     * broken. An app is always allowed to change its own components, so calling
     * this on every launch repairs it from the inside.
     *
     * Also guarantees at least one launcher entry exists: if every alias somehow
     * ended up disabled, the stock one is switched back on.
     */
    /**
     * The variant Dart wants, read straight from Flutter's SharedPreferences.
     *
     * Dart only ever WRITES this pref; the switch itself happens here, while the
     * app is in the background (see [syncFromPrefs]). Same cross-language pref
     * trick AlarmScheduler uses.
     */
    private fun desiredVariant(context: Context): String {
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE
        )
        val v = prefs.getString("flutter.auvy_app_icon_variant", "") ?: ""
        return if (isKnown(v)) v else ""
    }

    /** The alias currently acting as the launcher entry, or null if none is. */
    private fun activeVariant(context: Context): String? {
        val pm = context.packageManager
        return aliases.entries.firstOrNull { (_, cls) ->
            when (pm.getComponentEnabledSetting(
                ComponentName(context.packageName, cls)
            )) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                // No override means "whatever the manifest says", and only the
                // stock alias ships enabled.
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> cls == DEFAULT_ALIAS
                else -> false
            }
        }?.key
    }

    /**
     * Bring the launcher icon in line with the stored preference.
     *
     * Call this ONLY when the app is not in the foreground (MainActivity.onStop).
     *
     * `apply()` has to disable the alias that is no longer wanted — and that alias
     * is usually the very component the current task was launched from. Android
     * removes a task whose root component becomes disabled, so doing this while
     * visible closed the app the instant you changed accent colour.
     * `DONT_KILL_APP` does not help: it prevents the process being killed, not the
     * task being torn down. Deferring to onStop makes it invisible — by the time
     * you're looking at the launcher, the icon has already changed.
     */
    fun syncFromPrefs(context: Context, protect: String? = null) {
        val wanted = desiredVariant(context)
        if (activeVariant(context) == wanted) return // already correct
        apply(context, wanted, protect)
    }

    fun repair(context: Context, protect: String? = null) {
        val pm = context.packageManager
        try {
            // COMPONENT_ENABLED_STATE_DEFAULT (not _ENABLED) restores the
            // manifest's own value and clears the explicit override entirely,
            // which is what we want: MainActivity's manifest state is enabled.
            pm.setComponentEnabledSetting(
                ComponentName(context.packageName, TARGET),
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT,
                PackageManager.DONT_KILL_APP,
            )

            // Enforce EXACTLY one enabled launcher entry — not merely "at least
            // one". Adding `.MainActivityDefault` (which ships enabled) to a device
            // that already had an explicit override on a colour alias left BOTH
            // enabled, i.e. Auvy listed twice in the launcher.
            //
            // "Effectively enabled" folds in the manifest default, since a
            // component with no override reports DEFAULT rather than ENABLED.
            val enabled = aliases.filter { (_, cls) ->
                when (pm.getComponentEnabledSetting(
                    ComponentName(context.packageName, cls)
                )) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                    PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> cls == DEFAULT_ALIAS
                    else -> false
                }
            }.keys

            if (enabled.size != 1) {
                // The stored preference is the single source of truth for which
                // icon is wanted, so a corrupt component set is normalised to that
                // rather than guessed at from the states themselves.
                //
                // [protect] is honoured here too: this runs at STARTUP, so without
                // it a corrupt set would be "repaired" by disabling the alias the
                // user just launched from — killing the app on open.
                apply(context, desiredVariant(context), protect)
            }
        } catch (_: Exception) {
            // Best-effort: never let icon housekeeping stop the app from starting.
        }
    }

    /**
     * Enable [variant]'s alias and disable the others.
     *
     * The target is enabled BEFORE the rest are disabled — the other order leaves
     * a window with zero enabled launcher components, which some launchers latch
     * onto and render as the app disappearing.
     *
     * DONT_KILL_APP matters here: without it the system tears the process down the
     * moment its component set changes, so the app would die mid-playback the
     * instant you picked an icon. Launchers may still take a few seconds to
     * refresh their icon cache afterwards — that's the launcher, not this call.
     */
    fun apply(context: Context, variant: String, protect: String? = null): Boolean {
        val targetAlias = aliases[variant] ?: return false
        val pm = context.packageManager

        try {
            pm.setComponentEnabledSetting(
                ComponentName(context.packageName, targetAlias),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                PackageManager.DONT_KILL_APP,
            )
            for ((key, cls) in aliases) {
                if (key == variant) continue
                // [protect] is the component THIS TASK WAS LAUNCHED FROM. Disabling
                // it tears the task down — DONT_KILL_APP spares the process, not the
                // task, which is how a swap performed while the app was merely
                // BACKGROUNDED (the Google account picker takes foreground, so
                // onStop fires) closed the app in the middle of signing in, every
                // time on a fresh install.
                //
                // Leaving it enabled costs a second launcher entry until the app is
                // next closed for good, at which point the swap runs from
                // onDestroy/isFinishing where the teardown is harmless and
                // invisible. A duplicate icon for one session beats killing a live
                // session mid-login.
                if (protect != null && cls == protect) continue
                pm.setComponentEnabledSetting(
                    ComponentName(context.packageName, cls),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
            return true
        } catch (e: Exception) {
            // A failure part-way through could leave nothing enabled, i.e. no way
            // to launch the app. Restore the stock entry DIRECTLY rather than via
            // repair() — repair() calls back into apply(), and the two would
            // recurse into each other while the PackageManager is still failing.
            try {
                pm.setComponentEnabledSetting(
                    ComponentName(context.packageName, DEFAULT_ALIAS),
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                    PackageManager.DONT_KILL_APP,
                )
            } catch (_: Exception) {
            }
            return false
        }
    }
}
