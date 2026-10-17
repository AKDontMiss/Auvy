package com.auvy.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.widget.RemoteViews

/**
 * "Your Mixes": Liked Songs, Weekly Discovery, My Top 50 and everything
 * shuffled, one tap each. The iPhone has the same widget (AuvyMixesWidget).
 *
 * With Auvy running a tile is a command to it (it plays without opening);
 * with Auvy closed the tile opens the app, which then plays. Redrawn when the
 * accent changes and when Auvy starts or stops taking commands.
 */
class MixesWidgetProvider : AppWidgetProvider() {

    companion object {
        internal const val ACTION_MIX = "com.auvy.app.widget.MIX"
        internal const val EXTRA_MIX = "mix"
        internal const val EXTRA_SHUFFLE = "shuffle"

        private data class Mix(val view: Int, val icon: Int, val id: String, val shuffle: Boolean)

        private val mixes = listOf(
            Mix(R.id.mix_liked, R.id.mix_liked_icon, "liked", true),
            Mix(R.id.mix_weekly, R.id.mix_weekly_icon, "weekly", false),
            Mix(R.id.mix_top, R.id.mix_top_icon, "top50", false),
            Mix(R.id.mix_all, R.id.mix_all_icon, "library", true),
        )

        fun renderAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, MixesWidgetProvider::class.java))
            for (id in ids) render(context, mgr, id)
        }

        private fun render(context: Context, mgr: AppWidgetManager, id: Int) {
            val views = if (Build.VERSION.SDK_INT >= 31) {
                RemoteViews(mapOf(
                    SizeF(110f, 50f) to build(context, R.layout.widget_mixes),
                    SizeF(110f, 110f) to build(context, R.layout.widget_mixes_grid),
                    SizeF(220f, 50f) to build(context, R.layout.widget_mixes),
                ))
            } else {
                val o = mgr.getAppWidgetOptions(id)
                val w = o?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
                val h = o?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
                build(context, if (h >= 110 && w < 220) R.layout.widget_mixes_grid else R.layout.widget_mixes)
            }
            mgr.updateAppWidget(id, views)
        }

        private fun build(context: Context, layout: Int): RemoteViews {
            val views = RemoteViews(context.packageName, layout)
            val accent = WidgetBridge.prefs(context).getInt("accent", 0xFF53B1E1.toInt())
            for ((i, mix) in mixes.withIndex()) {
                views.setInt(mix.icon, "setColorFilter", accent)
                views.setOnClickPendingIntent(
                    mix.view,
                    if (AuvyCommands.isLive) {
                        PendingIntent.getBroadcast(
                            context, 60 + i,
                            Intent(context, WidgetActionReceiver::class.java)
                                .setAction(ACTION_MIX)
                                .putExtra(EXTRA_MIX, mix.id)
                                .putExtra(EXTRA_SHUFFLE, mix.shuffle),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    } else {
                        AuvyCommands.commandPendingIntent(
                            context, 70 + i, "playCollection",
                            "id" to mix.id, "shuffle" to mix.shuffle, "from" to "widget")
                    })
            }
            return views
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) render(context, mgr, id)
    }

    override fun onAppWidgetOptionsChanged(context: Context, mgr: AppWidgetManager, id: Int, newOptions: Bundle?) {
        render(context, mgr, id)
    }
}
