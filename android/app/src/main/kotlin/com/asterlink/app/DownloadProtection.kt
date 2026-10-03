package com.asterlink.app

import android.app.Activity
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat

class DownloadProtection(private val context: Context, private val keeper: DownloadKeepAlive) {
    fun status(): Map<String, Any> {
        val power = context.getSystemService(PowerManager::class.java)
        val manager = context.getSystemService(NotificationManager::class.java)
        val channelEnabled = Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(FlutterDownloadService.CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        val appNotifications = NotificationManagerCompat.from(context).areNotificationsEnabled()
        val keepAliveChannelEnabled = Build.VERSION.SDK_INT < 26 ||
            manager.getNotificationChannel(AppKeepAliveService.CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE
        return mapOf(
            "batteryUnrestricted" to power.isIgnoringBatteryOptimizations(context.packageName),
            "notificationsEnabled" to (appNotifications && channelEnabled),
            "keepAliveNotificationsEnabled" to (appNotifications && keepAliveChannelEnabled),
            "keepAliveRunning" to ((context.applicationContext as? AppKeepAliveOwner)?.appKeepAlive?.running == true),
            "backgroundRestricted" to (Build.VERSION.SDK_INT >= 28 && context.getSystemService(ActivityManager::class.java).isBackgroundRestricted),
            "powerSaveMode" to power.isPowerSaveMode,
            "serviceRunning" to keeper.running,
            "wakeLockHeld" to keeper.wakeLockHeld,
            "recovering" to keeper.waitingForRestart
        )
    }

    fun open(kind: String, activity: Activity?) {
        check(activity != null && !activity.isFinishing) { "请先返回应用" }
        val app = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        val choices = when (kind) {
            "battery" -> if (context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)) {
                listOf(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), app)
            } else listOf(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), app
            )
            "notifications" -> if (Build.VERSION.SDK_INT >= 26) {
                val appNotifications = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                // Both startup and download channels are managed on this page.
                listOf(appNotifications, app)
            } else listOf(app)
            else -> listOf(app)
        }
        for (intent in choices) {
            try {
                activity.startActivity(intent)
                return
            } catch (_: android.content.ActivityNotFoundException) {
                // Some vendors omit a standard settings page; try the next one.
            } catch (_: SecurityException) {
                // A managed device may reject the direct exemption request.
            }
        }
        error("无法打开系统后台设置")
    }
}
