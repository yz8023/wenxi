package com.asterlink.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat

interface AppKeepAliveOwner {
    val appKeepAlive: AppKeepAlive
}

/** Retains a user-opened session independently of download recovery state. */
class AppKeepAlive(
    private val context: Context,
    private val report: (String, Throwable) -> Unit = { _, _ -> }
) {
    private val main = Handler(Looper.getMainLooper())
    private val preferences = context.getSharedPreferences("app_keepalive", Context.MODE_PRIVATE)
    private var service: AppKeepAliveService? = null
    private var starting = false
    private val startTimeout = Runnable {
        if (starting) failed(IllegalStateException("应用保活服务启动超时"))
    }
    val running: Boolean get() = service != null
    private var wanted: Boolean
        get() = preferences.getBoolean("wanted", false)
        set(value) {
            if (wanted != value) preferences.edit().putBoolean("wanted", value).commit()
        }

    /** Only the resumed Activity starts this service; never Application.onCreate. */
    fun appVisible(activity: Activity) {
        if (activity.isFinishing || activity.isDestroyed) return
        if (service != null) {
            refresh()
        } else if (!starting) {
            wanted = true
            starting = true
            main.postDelayed(startTimeout, 8000)
            try {
                ContextCompat.startForegroundService(context, Intent(context, AppKeepAliveService::class.java))
            } catch (error: Exception) {
                failed(error)
            }
        }
        // Android permits FGS startup before this grant. If denied, the system
        // shows the service in its active-apps UI instead of the notification drawer.
        NotificationPermission.requestOnce(activity, report)
    }

    fun started(current: AppKeepAliveService): Boolean {
        service = current
        if (!wanted) {
            stop()
            return false
        }
        return try {
            current.show()
            starting = false
            main.removeCallbacks(startTimeout)
            true
        } catch (error: Exception) {
            failed(error)
            false
        }
    }

    fun refresh() {
        try {
            service?.show()
        } catch (error: Exception) {
            failed(error)
        }
    }

    fun destroyed(current: AppKeepAliveService) {
        if (service === current) service = null
        // START_STICKY lets Android decide whether to recreate the service.
        // No alarms, task-removal hooks or immediate restart loops.
    }

    fun stop() {
        wanted = false
        starting = false
        main.removeCallbacks(startTimeout)
        service?.finish()
        service = null
        context.stopService(Intent(context, AppKeepAliveService::class.java))
    }

    private fun failed(error: Throwable) {
        stop()
        report("keepalive.foreground_failed", error)
    }
}
