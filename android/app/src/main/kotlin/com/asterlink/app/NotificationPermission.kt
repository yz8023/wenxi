package com.asterlink.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** Shared by startup and downloads so Android's prompt appears only once. */
object NotificationPermission {
    const val REQUEST_CODE = 832

    fun granted(context: Context): Boolean = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun requestOnce(activity: Activity?, report: (String, Throwable) -> Unit = { _, _ -> }) {
        if (activity == null || activity.isFinishing || activity.isDestroyed || granted(activity)) return
        val preferences = activity.getSharedPreferences("asterlink_flutter_permissions", Context.MODE_PRIVATE)
        if (preferences.getBoolean("notificationsAsked", false)) return
        preferences.edit().putBoolean("notificationsAsked", true).apply()
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
        } catch (error: Exception) {
            // A denied/unsupported prompt must not prevent the app or downloads
            // from starting. The protection page can open notification settings.
            report("notifications.permission_failed", error)
        }
    }
}
