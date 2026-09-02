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
 * Wake-up alarm that starts MUSIC instead of a ringtone.
 *
 * Why this is native: a Dart `Timer` dies with the process, and Android kills
 * idle apps aggressively (this device especially — see the battery-optimisation
 * prompt). Only `AlarmManager` survives Doze and app death, so the schedule lives
 * here and Dart only says "wake me at 07:30 on these days".
 *
 * Flow: [AlarmScheduler.schedule] → exact alarm → [AlarmReceiver] → launches
 * MainActivity with EXTRA_ALARM so Dart knows to start playback → Dart reads it
 * via the `alarm` channel's `consumePendingAlarm` and plays the chosen source.
 *
 * The receiver deliberately does NOT try to start playback itself: the whole
 * resolve/queue/audio-focus pipeline lives in Dart, and duplicating any of it
 * natively is how the two-audio-focus-owners bug happened.
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
     * SLOT 8 IS THE SNOOZE, AND IT USED TO SURVIVE THIS ENTIRELY. The weekday
     * loop stops at 7, so switching the alarm OFF left a pending snooze armed and
     * the phone rang at a time no longer on any schedule, from an alarm the user
     * had just turned off. [includeSnooze] closes that.
     *
     * It is a parameter rather than unconditional because [schedule] begins by
     * cancelling: saving any alarm setting — the volume, the fade — would
     * otherwise silently call off a snooze the user is currently waiting on. A
     * snooze means "ring again in ten minutes" and is independent of what time the
     * alarm is set for.
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

        // SOUND FIRST, UI SECOND. This used to post a notification and hope
        // the user tapped it; everything below is now only about SHOWING the
        // app, because AlarmAudioService is already making noise by the time it
        // runs. Receiving your own exact alarm is one of the sanctioned
        // exemptions from the background foreground-service restriction, which
        // is exactly why the schedule uses setAlarmClock.
        AlarmAudioService.start(context)

        // A repeating alarm lost each day the moment it fired
        //
        // THE BUG THIS FIXES. setAlarmClock is ONE-SHOT: firing consumes the
        // PendingIntent. Arming happened in exactly three places — a reboot, the
        // user changing a setting, and a cloud restore, and nowhere after a
        // fire. `main.dart` calls AlarmService.reloadFrom() on launch, which
        // loads the values into memory and schedules nothing.
        //
        // So a weekday alarm rang once and then never again on that weekday. With
        // several days selected it degraded one day per week, silently, and the
        // settings screen still showed it enabled and set — a half-restored alarm
        // by another route, and the failure mode is not noticing you overslept.
        //
        // Re-armed natively rather than from Dart, because the app is usually not
        // running at 07:00 and this must not depend on it being opened. The whole
        // WEEK is re-armed rather than just today: each day has its own
        // PendingIntent so setAlarmClock simply replaces the identical one, which
        // makes every fire a chance to heal any day that was somehow lost.
        reArmRepeats(context)

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(AlarmScheduler.EXTRA_ALARM, true)
        }

        // NO "TAP TO START YOUR MUSIC" NOTIFICATION ANY MORE.
        //
        // This used to post its own high-importance notification whose only job
        // was to carry a full-screen intent and, failing that, to be tapped. Both
        // jobs moved: AlarmAudioService is already playing by the time this runs,
        // and ITS foreground notification carries the same full-screen intent — so
        // a second one was a duplicate card telling the user to start music that
        // was audibly already started.
        //
        // A bare startActivity() from a background receiver is still blocked on
        // Android 10+, so it stays a best-effort: it succeeds when Auvy is already
        // foreground and makes the alarm screen instant in that case, and is
        // harmless when refused because the service's full-screen intent covers
        // the locked-phone path. singleTop means no duplicate activity either way.
        try {
            context.startActivity(launch)
        } catch (e: Exception) {
            Log.i("AuvyAlarm", "direct start unavailable (expected in background): ${e.message}")
        }
    }

    /**
     * Re-arm a REPEATING alarm after one of its days has fired.
     *
     * Reads the same SharedPreferences file the boot path does — launching Flutter
     * to reschedule would be far heavier, and at 07:00 the app is usually dead.
     *
     * A one-shot alarm (no days selected) is deliberately NOT re-armed: firing
     * once is the whole of what the user asked for, and rescheduling it for
     * tomorrow would be inventing an alarm they never set.
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
