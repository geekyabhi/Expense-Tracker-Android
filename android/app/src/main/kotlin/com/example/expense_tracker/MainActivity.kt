package com.example.expense_tracker

import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Revive the watcher after an app update / process death (we're in the foreground here).
        val overlay = Settings.canDrawOverlays(this)
        val watcherReady = Prefs.enabled(this) && hasUsageAccess() && overlay
        val bubbleReady = Prefs.bubble(this) && overlay
        if (watcherReady || bubbleReady) {
            try { WatcherService.start(this) } catch (_: Exception) {}
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "expense_tracker/watcher")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledApps" -> Thread {
                        try {
                            val apps = installedApps()
                            runOnUiThread { result.success(apps) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("apps", e.message, null) }
                        }
                    }.start()

                    "getWatched" -> result.success(Prefs.watched(this).toList())
                    "setWatched" -> {
                        val list = call.argument<List<String>>("packages") ?: emptyList()
                        Prefs.setWatched(this, list.toSet())
                        result.success(null)
                    }

                    "setNotion" -> {
                        Prefs.setNotion(
                            this,
                            call.argument<String>("token") ?: "",
                            call.argument<String>("databaseId") ?: "",
                            call.argument<Boolean>("autoSync") ?: true
                        )
                        result.success(null)
                    }

                    "previewPopup" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("overlay", "Grant Display over other apps first", null)
                        } else {
                            ExpensePopup(this, "Expensive", packageName, preview = true).show()
                            result.success(null)
                        }
                    }

                    "isEnabled" -> result.success(Prefs.enabled(this))
                    "setEnabled" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        Prefs.setEnabled(this, on)
                        if (on) askNotificationPermission()
                        WatcherService.refresh(this)
                        result.success(null)
                    }

                    "isBubbleEnabled" -> result.success(Prefs.bubble(this))
                    "setBubbleEnabled" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        if (on && !Settings.canDrawOverlays(this)) {
                            result.error("overlay", "Grant Display over other apps first", null)
                        } else {
                            Prefs.setBubble(this, on)
                            if (on) askNotificationPermission()
                            WatcherService.refresh(this)
                            result.success(null)
                        }
                    }

                    "permissionStatus" -> result.success(
                        mapOf(
                            "usage" to hasUsageAccess(),
                            "overlay" to Settings.canDrawOverlays(this),
                            "battery" to ignoringBattery()
                        )
                    )

                    "openUsageSettings" -> {
                        startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
                        result.success(null)
                    }
                    "openOverlaySettings" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    }
                    "requestIgnoreBattery" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                        )
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 1)
        }
    }

    @Suppress("DEPRECATION")
    private fun hasUsageAccess(): Boolean {
        val ops = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= 29)
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        else
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), packageName)
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun ignoringBattery(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /** Launchable apps (those with an icon in the app drawer), sorted by name. */
    @Suppress("DEPRECATION")
    private fun installedApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(launcher, PackageManager.MATCH_ALL)
            .asSequence()
            .map { it.activityInfo.applicationInfo }
            .filter { it.packageName != packageName }
            .distinctBy { it.packageName }
            .map { info ->
                mapOf(
                    "name" to pm.getApplicationLabel(info).toString(),
                    "package" to info.packageName,
                    "icon" to iconPng(pm.getApplicationIcon(info))
                )
            }
            .sortedBy { (it["name"] as String).lowercase() }
            .toList()
    }

    private fun iconPng(d: Drawable): ByteArray {
        val size = 96
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(canvas)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }
}
