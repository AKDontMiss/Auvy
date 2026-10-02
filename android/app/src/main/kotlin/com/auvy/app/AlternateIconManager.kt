package com.auvy.app

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

/**
 * Switches the launcher icon between the aliases declared in AndroidManifest.xml.
 *
 * Android has no "set icon" API: each icon is a separate launcher component,
 * and you enable the one you want. Two rules keep the app reachable from the
 * home screen:
 *
 * 1. **Exactly one alias enabled.** Two shows the app twice; zero hides it.
 *    So [apply] always rewrites the whole set.
 *
 * 2. **Never disable [TARGET].** MainActivity is the `targetActivity` of every
 *    alias; disabling it makes Android report "app is unavailable". The
 *    default icon is its own alias ([DEFAULT_ALIAS]), and MainActivity is only
 *    ever touched by [repair] to switch it back on.
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
     * Repair a broken or partially applied icon state.
     *
     * Component enabled-state survives app updates, so a device where
     * MainActivity was once disabled would stay broken without this. Called on
     * every launch. Also makes sure at least one launcher entry exists.
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
     * Called from MainActivity.onDestroy when the app is closing for good.
     * Disabling the alias the current task was launched from removes the task
     * (DONT_KILL_APP keeps the process, not the task), so doing it while the app
     * is in use would close it.
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

            // Enforce exactly one enabled launcher entry, not merely "at least one".
            // "Effectively enabled" includes the manifest default, since a component
            // with no override reports DEFAULT rather than ENABLED.
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
                // The stored preference decides which icon is wanted, so a corrupt set is
                // normalised to it. [protect] applies here too: this runs at startup, and
                // disabling the alias the user just launched from would close the app.
                apply(context, desiredVariant(context), protect)
            }
        } catch (_: Exception) {
            // Best-effort: never let icon housekeeping stop the app from starting.
        }
    }

    /**
     * Enable [variant]'s alias and disable the others.
     *
     * The target is enabled before the rest are disabled, so there is never a
     * moment with zero launcher entries.
     *
     * DONT_KILL_APP stops the system killing the process when its components
     * change. Launchers may take a few seconds to refresh their icon cache.
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
                // Skip [protect], the component this task was launched from: disabling it
                // would close the app (e.g. mid sign-in, when the account picker triggers
                // onStop). The extra launcher entry only lasts until the app is fully
                // closed, when the swap runs again from onDestroy.
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
