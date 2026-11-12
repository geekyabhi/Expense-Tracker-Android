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

    fun backendUrl(c: Context) = sp(c).getString("backend_url", "") ?: ""
    fun backendToken(c: Context) = sp(c).getString("backend_token", "") ?: ""
    fun autoSync(c: Context) = sp(c).getBoolean("auto_sync", true)

    /** The server, the signed-in token (empty when signed out) and Auto/Manual. */
    fun setBackend(c: Context, url: String, token: String, autoSync: Boolean) =
        sp(c).edit()
            .putString("backend_url", url)
            .putString("backend_token", token)
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
