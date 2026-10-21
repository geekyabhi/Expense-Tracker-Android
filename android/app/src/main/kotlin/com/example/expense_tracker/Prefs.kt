package com.example.expense_tracker

import android.content.Context

/** Settings shared between the Flutter UI (via MethodChannel) and the native watcher. */
object Prefs {
    private fun sp(c: Context) =
        c.getSharedPreferences("expense_tracker_prefs", Context.MODE_PRIVATE)

    fun watched(c: Context): Set<String> =
        sp(c).getStringSet("watched", emptySet()) ?: emptySet()

    fun setWatched(c: Context, packages: Set<String>) =
        sp(c).edit().putStringSet("watched", HashSet(packages)).apply()

    fun enabled(c: Context) = sp(c).getBoolean("enabled", false)
    fun setEnabled(c: Context, v: Boolean) = sp(c).edit().putBoolean("enabled", v).apply()

    fun notionToken(c: Context) = sp(c).getString("notion_token", "") ?: ""
    fun notionDb(c: Context) = sp(c).getString("notion_db", "") ?: ""
    fun autoSync(c: Context) = sp(c).getBoolean("auto_sync", true)
    fun setNotion(c: Context, token: String, databaseId: String, autoSync: Boolean) =
        sp(c).edit()
            .putString("notion_token", token)
            .putString("notion_db", databaseId)
            .putBoolean("auto_sync", autoSync)
            .apply()

    fun bubble(c: Context) = sp(c).getBoolean("bubble", false)
    fun setBubble(c: Context, v: Boolean) = sp(c).edit().putBoolean("bubble", v).apply()
    fun bubbleRight(c: Context) = sp(c).getBoolean("bubble_right", true)
    fun bubbleCy(c: Context) = sp(c).getInt("bubble_cy", -1)
    /** [cy] is the vertical centre of the tab, in pixels. */
    fun setBubblePos(c: Context, right: Boolean, cy: Int) =
        sp(c).edit().putBoolean("bubble_right", right).putInt("bubble_cy", cy).apply()
}
