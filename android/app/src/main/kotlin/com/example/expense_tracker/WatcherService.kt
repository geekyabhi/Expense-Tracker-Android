package com.example.expense_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings

/**
 * One foreground service for both overlay features:
 *  - the app watcher: polls the foreground app once a second and shows the
 *    expense popup when a watched app stops being in front;
 *  - the floating "+" button, which opens the same popup when tapped.
 * Each runs only while its switch is on; the service stops when neither is.
 */
class WatcherService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastEventTs = 0L
    private var fg: String? = null
    private var lastTrigger = 0L
    private var popup: ExpensePopup? = null
    private var bubble: FloatingBubble? = null

    private val poll = object : Runnable {
        override fun run() {
            try { check() } catch (_: Exception) {}
            handler.postDelayed(this, 1000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Also called each time a switch changes, to apply the new state. */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundNotification()
        applyState()
        return START_STICKY
    }

    private fun applyState() {
        val watch = Prefs.enabled(this)
        val wantBubble = Prefs.bubble(this)
        if (!watch && !wantBubble) {
            stopSelf()
            return
        }

        // App watcher
        handler.removeCallbacks(poll)
        if (watch) {
            if (lastEventTs == 0L) lastEventTs = System.currentTimeMillis()
            handler.post(poll)
        }

        // Floating button
        if (wantBubble && Settings.canDrawOverlays(this)) {
            val b = bubble ?: FloatingBubble(this) { openQuickAdd() }.also { bubble = it }
            b.show()
        } else {
            bubble?.remove()
            bubble = null
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        bubble?.reposition()
    }

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        popup?.dismiss()
        bubble?.remove()
        bubble = null
        super.onDestroy()
    }

    private fun openQuickAdd() {
        if (popup?.isShowing == true) return
        if (!Settings.canDrawOverlays(this)) return
        popup = ExpensePopup(this, null, packageName).also { it.show() }
    }

    private fun check() {
        val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val events = usm.queryEvents(lastEventTs + 1, System.currentTimeMillis())
        val e = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(e)
            if (e.timeStamp > lastEventTs) lastEventTs = e.timeStamp
            if (e.eventType == UsageEvents.Event.ACTIVITY_RESUMED) onForeground(e.packageName)
        }
    }

    private fun onForeground(pkg: String) {
        if (pkg == fg) return
        if (pkg == "com.android.systemui") return // shade / recents, not a real switch
        val prev = fg
        fg = pkg
        if (pkg == packageName) return // opening our own app never triggers the popup
        if (prev != null && prev in Prefs.watched(this)) trigger(prev)
    }

    private fun trigger(closedPkg: String) {
        val now = System.currentTimeMillis()
        if (now - lastTrigger < 3000) return
        if (popup?.isShowing == true) return
        if (!Settings.canDrawOverlays(this)) return
        lastTrigger = now
        val label = try {
            packageManager.getApplicationLabel(packageManager.getApplicationInfo(closedPkg, 0)).toString()
        } catch (_: Exception) {
            closedPkg
        }
        popup = ExpensePopup(this, label, closedPkg).also { it.show() }
    }

    private fun startForegroundNotification() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("watcher", "Quick add", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val text = when {
            Prefs.enabled(this) && Prefs.bubble(this) ->
                "Watching your selected apps, floating + button on"
            Prefs.enabled(this) -> "Watching your selected apps"
            else -> "Floating + button is on"
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "watcher")
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setContentTitle("Expensive")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_notify)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, n)
        }
    }

    companion object {
        fun start(ctx: Context) {
            val i = Intent(ctx, WatcherService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, WatcherService::class.java))
        }

        /** Starts (or re-applies) the service if either feature is on, else stops it. */
        fun refresh(ctx: Context) {
            if (Prefs.enabled(ctx) || Prefs.bubble(ctx)) start(ctx) else stop(ctx)
        }
    }
}
