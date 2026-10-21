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
 * uses, then tries to push it to Notion right away. If that isn't possible
 * (offline, not set up, rejected) the row stays not-uploaded and the user pushes
 * it manually from the app.
 *
 * Must be called off the main thread.
 */
object ExpenseStore {
    /** Returns true if the expense also reached Notion. */
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

        val pageId = createNotionPage(ctx, title, amount, category, mode, now) ?: return false

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

    private fun tags(v: String): JSONArray =
        JSONArray().apply { if (v.isNotBlank()) put(JSONObject().put("name", v.replace(",", " ").trim())) }

    /** Mirrors ApiService.upload in Dart. Returns the new Notion page id, or null. */
    private fun createNotionPage(
        ctx: Context, title: String, amount: Double, category: String, mode: String, at: Date
    ): String? {
        val token = Prefs.notionToken(ctx).trim()
        val dbId = Prefs.notionDb(ctx).trim()
        if (token.isEmpty() || dbId.isEmpty()) return null

        val body = JSONObject().apply {
            put("parent", JSONObject().put("database_id", dbId))
            put("properties", JSONObject().apply {
                put("Expense", JSONObject().put("title", JSONArray().put(
                    JSONObject().put("text", JSONObject().put("content", title)))))
                put("Amount", JSONObject().put("number", amount))
                put("Date", JSONObject().put("date", JSONObject().put("start",
                    SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.US).format(at))))
                put("Category", JSONObject().put("multi_select", tags(category)))
                put("Source", JSONObject().put("multi_select", tags("")))
                put("Mode", JSONObject().put("multi_select", tags(mode)))
            })
        }

        return try {
            val conn = URL("https://api.notion.com/v1/pages").openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 10_000
                conn.readTimeout = 15_000
                conn.doOutput = true
                conn.setRequestProperty("Authorization", "Bearer $token")
                conn.setRequestProperty("Notion-Version", "2022-06-28")
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
                if (conn.responseCode in 200..299) {
                    JSONObject(conn.inputStream.bufferedReader().readText()).optString("id").ifEmpty { null }
                } else {
                    null // 4xx/5xx: leave it on the device for a manual push
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            null // offline, timeout, DNS failure...
        }
    }
}
