package com.example.expense_tracker

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Saves an expense into the same sqflite database (expenses.db) the Flutter app
 * uses, then, in Auto mode and when signed in, uploads it to the server right
 * away. If that isn't possible (offline, signed out, rejected) the row stays
 * not-uploaded and the user pushes it manually from the app.
 *
 * Must be called off the main thread.
 */
object ExpenseStore {
    /** Returns true if the expense also reached the server. */
    fun save(
        ctx: Context, title: String, amount: Double, category: String, note: String, mode: String
    ): Boolean {
        val id = UUID.randomUUID().toString()
        val now = Date()
        // Same shape as Dart's DateTime.toIso8601String() for a local time.
        val date = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(now)

        val dbFile = ctx.getDatabasePath("expenses.db")
        dbFile.parentFile?.mkdirs()
        val db = SQLiteDatabase.openOrCreateDatabase(dbFile, null)
        try {
            ensureSchema(db)
            db.insertOrThrow("expenses", null, ContentValues().apply {
                put("id", id)
                put("title", title)
                put("amount", amount)
                put("category", category)
                put("date", date)
                put("note", note)
                put("source", "")
                put("mode", mode)
                put("synced", 0)
            })
        } finally {
            db.close()
        }

        if (!Prefs.autoSync(ctx)) return false // Manual mode: never upload from here

        val pageId = createRemote(ctx, title, amount, category, note, mode, now) ?: return false

        val db2 = SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE)
        try {
            db2.execSQL(
                "UPDATE expenses SET synced = 1, remote_id = ? WHERE id = ?",
                arrayOf(pageId, id)
            )
        } finally {
            db2.close()
        }
        return true
    }

    /**
     * Brings the database to schema version 3 (what the Flutter app expects),
     * whether it doesn't exist yet or is still on an older layout.
     */
    private fun ensureSchema(db: SQLiteDatabase) {
        val v = db.version
        if (v >= 3) return
        if (v == 0) {
            db.execSQL(
                "CREATE TABLE IF NOT EXISTS expenses(" +
                    "id TEXT PRIMARY KEY, title TEXT NOT NULL, amount REAL NOT NULL, " +
                    "category TEXT NOT NULL, date TEXT NOT NULL, note TEXT, " +
                    "source TEXT NOT NULL DEFAULT '', mode TEXT NOT NULL DEFAULT '', " +
                    "synced INTEGER NOT NULL DEFAULT 0, remote_id TEXT, " +
                    "processed INTEGER NOT NULL DEFAULT 0)"
            )
        } else {
            if (v < 2) {
                db.execSQL("ALTER TABLE expenses ADD COLUMN source TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE expenses ADD COLUMN mode TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE expenses ADD COLUMN remote_id TEXT")
                db.execSQL("UPDATE expenses SET synced = 0") // same as the Dart upgrade
            }
            db.execSQL("ALTER TABLE expenses ADD COLUMN processed INTEGER NOT NULL DEFAULT 0")
        }
        db.execSQL("CREATE TABLE IF NOT EXISTS pending_deletes(remote_id TEXT PRIMARY KEY)")
        db.version = 3 // sqflite runs onCreate only while user_version is 0
    }

    /**
     * Creates the expense on the server (POST /api/expenses/create/), the same
     * request the Flutter side makes. Returns the server's id ("page_id") of the
     * new expense, or null when it could not be created (then it stays on the
     * phone, not uploaded).
     */
    private fun createRemote(
        ctx: Context, title: String, amount: Double, category: String,
        note: String, mode: String, at: Date
    ): String? {
        val base = Prefs.backendUrl(ctx).trim().trimEnd('/')
        val token = Prefs.backendToken(ctx).trim()
        if (base.isEmpty() || token.isEmpty()) return null // signed out

        val body = JSONObject().apply {
            put("name", title)
            put("amount", amount)
            put("date", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(at))
            put("categories", JSONArray().put(category))
            put("source", "")
            put("mode", mode)
            put("comment", note)
        }

        return try {
            val conn = URL("$base/api/expenses/create/").openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 10_000
                conn.readTimeout = 15_000
                conn.doOutput = true
                conn.setRequestProperty("Authorization", "Bearer $token")
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Accept", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
                if (conn.responseCode in 200..299) {
                    val reply = JSONObject(conn.inputStream.bufferedReader().readText())
                    reply.opt("page_id")?.toString()?.ifEmpty { null }
                } else {
                    null // 401 (expired), 4xx or 5xx: leave it on the device
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            null // offline, timeout, DNS failure...
        }
    }
}
