package com.asterlink.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Startup notification; actual transfers and their wake lock use dataSync. */
class AppKeepAliveService : Service() {
    companion object {
        const val CHANNEL = "asterlink.keepalive"
        const val NOTIFICATION_ID = 408
    }
    private val keeper get() = (application as AppKeepAliveOwner).appKeepAlive
    private var foreground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "后台保活", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "打开应用后保持后台运行，点击通知返回应用"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        if (keeper.started(this)) START_STICKY else START_NOT_STICKY

    fun show() {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle("文析助手")
            .setContentText("后台保活中 · 点击返回应用")
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOnlyAlertOnce(true).setOngoing(true).setSilent(true).setShowWhen(false)
            .build()
        if (!foreground) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification,
                if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
            )
            foreground = true
        } else if (NotificationPermission.granted(this)) {
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }
    }

    fun finish() {
        releaseNotification()
        stopSelf()
    }

    private fun releaseNotification() {
        if (foreground) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        keeper.stop()
    }

    override fun onDestroy() {
        releaseNotification()
        keeper.destroyed(this)
        super.onDestroy()
    }
}
