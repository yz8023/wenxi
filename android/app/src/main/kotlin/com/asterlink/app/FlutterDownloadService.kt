package com.asterlink.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class FlutterDownloadService : Service() {
    companion object {
        const val CHANNEL = "asterlink.downloads"
        const val NOTIFICATION_ID = 407
        private const val LEASE_MS = 10 * 60 * 1000L
        private const val RENEW_MS = 5 * 60 * 1000L
    }
    private val keeper get() = (application as DownloadServiceOwner).downloadKeepAlive
    private val main = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var acquiredAt = 0L
    private var foreground = false
    private var lastNotice: DownloadNotice? = null
    val wakeLockHeld: Boolean get() = wakeLock?.isHeld == true
    private val maintenance = object : Runnable {
        override fun run() {
            if (!foreground) return
            if (!keeper.healthy()) {
                keeper.pause("downloadServiceStalled")
                return
            }
            renewWakeLock()
            main.postDelayed(this, 30000)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "下载任务", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "后台下载进度与暂停操作"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "pauseAll") {
            keeper.pause()
            return START_NOT_STICKY
        }
        return if (keeper.started(this, restarted = intent == null)) START_STICKY else START_NOT_STICKY
    }

    fun show(value: DownloadNotice, allowPause: Boolean = true) {
        if (foreground && lastNotice == value && allowPause) return
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val public = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("文析助手 · 后台下载")
            .setContentText("点击返回应用").build()
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("文析助手 · ${value.active} 个下载任务")
            .setContentText(value.text)
            .setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setOnlyAlertOnce(true).setOngoing(true).setSilent(true)
            .setProgress(100, value.progress.coerceAtLeast(0), value.progress < 0)
        if (allowPause) {
            val pause = PendingIntent.getService(
                this, 1, Intent(this, FlutterDownloadService::class.java).setAction("pauseAll"),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            builder.addAction(android.R.drawable.ic_media_pause, "全部暂停", pause)
        }
        val notification = builder.build()
        if (!foreground) {
            ServiceCompat.startForeground(
                this, NOTIFICATION_ID, notification,
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
            )
            foreground = true
            renewWakeLock()
            main.removeCallbacks(maintenance)
            main.postDelayed(maintenance, 30000)
        } else if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            // Notification refreshes do not attempt another background start.
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
        }
        lastNotice = value
    }

    private fun renewWakeLock() {
        if (wakeLock == null) {
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AsterLink:Downloads")
                .apply { setReferenceCounted(false) }
        }
        val now = SystemClock.elapsedRealtime()
        if (wakeLock?.isHeld != true || now - acquiredAt >= RENEW_MS) {
            // A lease expires even if a future bug stops maintenance callbacks.
            wakeLock?.acquire(LEASE_MS)
            acquiredAt = now
        }
    }

    fun finish() {
        releaseResources()
        stopSelf()
    }

    private fun releaseResources() {
        main.removeCallbacks(maintenance)
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        if (foreground) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foreground = false
        lastNotice = null
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Acknowledge Android 15+ dataSync limits synchronously; no restart loop.
        keeper.pause("serviceTimeout")
        finish()
    }

    override fun onDestroy() {
        releaseResources()
        keeper.destroyed(this)
        super.onDestroy()
    }
}
