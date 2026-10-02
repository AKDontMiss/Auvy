package com.auvy.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import java.util.Calendar

/**
 * Wake-up alarm that starts music instead of a ringtone.
 *
 * Native because a Dart `Timer` dies with the process; only `AlarmManager`
 * survives Doze and the app being killed. Dart just says "wake me at 07:30
 * on these days".
 *
 * Flow: [AlarmScheduler.schedule] → exact alarm → [AlarmReceiver] → starts
 * [AlarmAudioService] (which plays immediately) and tries to show
 * MainActivity with EXTRA_ALARM → Dart reads it via the `alarm` channel's
 * `consumePendingAlarm` and takes over playback.
 */
object AlarmScheduler {
    private const val TAG = "AuvyAlarm"
    const val EXTRA_ALARM = "auvy_alarm_fired"

    /** One request code per weekday so each day can be scheduled independently. */
    private fun requestCode(weekday: Int) = 8800 + weekday

    private fun pendingIntent(context: Context, weekday: Int, mutable: Boolean): PendingIntent {
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            action = "com.auvy.app.ALARM"
            putExtra("weekday", weekday)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        flags = flags or if (mutable) PendingIntent.FLAG_MUTABLE else PendingIntent.FLAG_IMMUTABLE
        return PendingIntent.getBroadcast(context, requestCode(weekday), intent, flags)
    }

    /**
     * (Re)schedule the alarm. [days] holds `Calendar.MONDAY`…`Calendar.SUNDAY`
     * values; an EMPTY set means "once, at the next occurrence".
     *
     * Always cancels everything first, so this is idempotent — calling it twice
     * can't leave a stale alarm from a previous time behind.
     */
    fun schedule(context: Context, hour: Int, minute: Int, days: Set<Int>) {
        // Not the snooze. See [cancel]. Rescheduling happens on every settings
        // save, and a snooze in flight is not part of the schedule.
        cancel(context, includeSnooze = false)
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

        // Android 12+ refuses exact alarms without the user's permission. Fall
        // back to an inexact alarm rather than throwing — a wake-up that may be a
        // few minutes late beats no alarm and a crash.
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.canScheduleExactAlarms()
        } else true

        val targets = if (days.isEmpty()) setOf(-1) else days
        for (day in targets) {
            val trigger = nextTrigger(hour, minute, day)
            val pi = pendingIntent(context, if (day == -1) 0 else day, mutable = false)
            try {
                if (canExact) {
                    // setAlarmClock: the strongest guarantee Android offers — exempt
                    // from Doze batching AND surfaced in the status bar so the user
                    // can see an alarm is armed.
                    am.setAlarmClock(AlarmManager.AlarmClockInfo(trigger, pi), pi)
                } else {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                }
                Log.i(TAG, "armed day=$day at ${hour}:${minute} exact=$canExact")
            } catch (e: SecurityException) {
                Log.w(TAG, "exact alarm refused: ${e.message}")
                try {
                    am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                } catch (_: Exception) {}
            }
        }
    }

    /**
     * Cancel the scheduled alarm.
     *
     * Request-code slot 8 is the snooze (the weekday loop only covers 1–7), so
     * it is cancelled too unless [includeSnooze] is false. [schedule] passes
     * false when it re-arms, so changing an alarm setting doesn't silently cancel
     * a snooze the user is waiting on.
     */
    fun cancel(context: Context, includeSnooze: Boolean = true) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        // 0 covers the one-shot slot, 1..7 the weekdays.
        for (day in 0..7) {
            try {
                am.cancel(pendingIntent(context, day, mutable = false))
            } catch (_: Exception) {}
        }
        if (includeSnooze) {
            try { AlarmAudioService.cancelSnooze(context) } catch (_: Exception) {}
        }
        Log.i(TAG, "alarms cancelled (snooze included: $includeSnooze)")
    }

    /** True when the OS will honour an EXACT alarm (Android 12+ gates this). */
    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return am.canScheduleExactAlarms()
    }

    /**
     * Next epoch-ms for [hour]:[minute]. [weekday] is a `Calendar` day, or -1 for
     * "the next time this clock time comes round".
     */
    private fun nextTrigger(hour: Int, minute: Int, weekday: Int): Long {
        val now = Calendar.getInstance()
        val c = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, hour)
            set(Calendar.MINUTE, minute)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (weekday in Calendar.SUNDAY..Calendar.SATURDAY) {
            // Walk forward to the requested weekday; if that lands in the past
            // (today, already gone), take next week's.
            var delta = (weekday - c.get(Calendar.DAY_OF_WEEK) + 7) % 7
            c.add(Calendar.DAY_OF_YEAR, delta)
            if (c.timeInMillis <= now.timeInMillis) c.add(Calendar.DAY_OF_YEAR, 7)
        } else if (c.timeInMillis <= now.timeInMillis) {
            c.add(Calendar.DAY_OF_YEAR, 1)
        }
        return c.timeInMillis
    }
}

/**
 * Fires at the alarm time and brings Auvy to the foreground with
 * [AlarmScheduler.EXTRA_ALARM] set. Dart takes it from there.
 *
 * Also re-arms after a reboot (BOOT_COMPLETED) — Android drops every alarm on
 * restart, so without this an alarm silently stops working the first time the
 * phone reboots, which is exactly when a user would rely on it.
 */
class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: ""

        // "Cancel snooze", tapped on the snoozed-alarm notification. Handled here
        // rather than in AlarmAudioService because that service is not running at
        // this point, and Android 12+ refuses a background service start — a
        // broadcast receiver has no such restriction.
        if (action == AlarmAudioService.ACTION_CANCEL_SNOOZE) {
            AlarmAudioService.cancelSnooze(context)
            return
        }

        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON"
        ) {
            // Re-arming needs the saved config, which lives in Dart's prefs. Read
            // the same SharedPreferences file directly — launching Flutter just to
            // reschedule would be far heavier than this.
            try {
                val prefs = context.getSharedPreferences(
                    "FlutterSharedPreferences", Context.MODE_PRIVATE)
                // A reboot drops EVERY alarm, the snooze one-shot included, so its
                // recorded fire time is now a lie. Cleared before the early return
                // below, because it is wrong whether or not the alarm is enabled.
                prefs.edit()
                    .remove("flutter.${AlarmAudioService.PREF_SNOOZE_AT}").apply()
                val enabled = prefs.getBoolean("flutter.auvy_alarm_enabled", false)
                if (!enabled) return
                val hour = prefs.getLong("flutter.auvy_alarm_hour", 7L).toInt()
                val minute = prefs.getLong("flutter.auvy_alarm_minute", 30L).toInt()
                val daysCsv = prefs.getString("flutter.auvy_alarm_days", "") ?: ""
                val days = daysCsv.split(',')
                    .mapNotNull { it.trim().toIntOrNull() }
                    .toSet()
                AlarmScheduler.schedule(context, hour, minute, days)
                Log.i("AuvyAlarm", "re-armed after boot")
            } catch (e: Exception) {
                Log.w("AuvyAlarm", "boot re-arm failed: ${e.message}")
            }
            return
        }

        Log.i("AuvyAlarm", "alarm fired — starting alarm audio")

        // Start the sound first: AlarmAudioService plays on its own, so everything
        // below is only about showing the app. Receiving your own exact alarm
        // (setAlarmClock) is an allowed exemption for starting a foreground service
        // from the background.
        AlarmAudioService.start(context)

        // setAlarmClock is one-shot, so a repeating alarm must be re-armed after
        // each fire or that weekday would never ring again. Done natively because
        // the app is usually not running at alarm time. The whole week is re-armed
        // (each day has its own PendingIntent, so this just replaces identical ones),
        // which also heals any day that was lost.
        reArmRepeats(context)

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(AlarmScheduler.EXTRA_ALARM, true)
        }

        // Best-effort launch of the alarm screen. Starting an activity from a
        // background receiver is blocked on Android 10+, so this only works when
        // Auvy is already in the foreground; otherwise the service's notification
        // carries the full-screen intent. singleTop avoids a duplicate activity.
        try {
            context.startActivity(launch)
        } catch (e: Exception) {
            Log.i("AuvyAlarm", "direct start unavailable (expected in background): ${e.message}")
        }
    }

    /**
     * Re-arm a repeating alarm after one of its days has fired.
     *
     * Reads the same SharedPreferences file the boot path does, since launching
     * Flutter just to reschedule would be much heavier.
     *
     * A one-shot alarm (no days selected) is not re-armed.
     */
    private fun reArmRepeats(context: Context) {
        try {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE)
            if (!prefs.getBoolean("flutter.auvy_alarm_enabled", false)) return
            val daysCsv = prefs.getString("flutter.auvy_alarm_days", "") ?: ""
            val days = daysCsv.split(',')
                .mapNotNull { it.trim().toIntOrNull() }
                .toSet()
            if (days.isEmpty()) return // one-shot: nothing to repeat
            val hour = prefs.getLong("flutter.auvy_alarm_hour", 7L).toInt()
            val minute = prefs.getLong("flutter.auvy_alarm_minute", 30L).toInt()
            AlarmScheduler.schedule(context, hour, minute, days)
            Log.i("AuvyAlarm", "re-armed ${days.size} repeating day(s) after firing")
        } catch (e: Exception) {
            Log.w("AuvyAlarm", "re-arm after firing FAILED: ${e.message} — this alarm will not ring again on this day until the app is opened")
        }
    }
}
