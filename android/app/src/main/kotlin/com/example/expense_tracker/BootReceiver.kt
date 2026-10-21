package com.example.expense_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the background service after a reboot if either feature was on. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && (Prefs.enabled(context) || Prefs.bubble(context))) {
            try { WatcherService.start(context) } catch (_: Exception) {}
        }
    }
}
