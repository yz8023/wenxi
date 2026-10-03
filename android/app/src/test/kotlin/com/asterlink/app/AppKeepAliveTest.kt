package com.asterlink.app

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager
import java.time.Duration

class KeepAliveTestApplication : Application(), AppKeepAliveOwner, DownloadServiceOwner {
    override lateinit var appKeepAlive: AppKeepAlive
    override lateinit var downloadKeepAlive: DownloadKeepAlive
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35], manifest = Config.NONE, application = KeepAliveTestApplication::class)
class AppKeepAliveTest {
    private lateinit var app: KeepAliveTestApplication
    private val activities = mutableListOf<ActivityController<Activity>>()
    private val services = mutableListOf<ServiceController<AppKeepAliveService>>()
    private val downloads = mutableListOf<ServiceController<FlutterDownloadService>>()
    private val commands = mutableListOf<String>()
    private val errors = mutableListOf<String>()
    private val keeper get() = app.appKeepAlive
    private class Reply : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) { fail(message) }
        override fun notImplemented() { fail("not implemented") }
    }
    private fun newKeeper() {
        app.appKeepAlive = AppKeepAlive(app) { name, _ -> errors.add(name) }
    }
    private fun activity(): Activity = Robolectric.buildActivity(Activity::class.java)
        .also { activities.add(it); it.setup() }.get()
    private fun service(): AppKeepAliveService = Robolectric.buildService(AppKeepAliveService::class.java)
        .also { services.add(it); it.create() }.get()
    private fun start(): AppKeepAliveService {
        keeper.appVisible(activity())
        return service().also { assertEquals(Service.START_STICKY, it.onStartCommand(Intent(), 0, 1)) }
    }
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication() as KeepAliveTestApplication
        for (name in listOf("app_keepalive", "download_keepalive", "asterlink_flutter_permissions")) {
            app.getSharedPreferences(name, Context.MODE_PRIVATE).edit().clear().commit()
        }
        newKeeper()
        app.downloadKeepAlive = DownloadKeepAlive(app, { name, callback -> commands.add(name); callback(true) })
    }
    @After fun cleanup() {
        keeper.stop()
        app.downloadKeepAlive.update(DownloadNotice.IDLE, Reply())
        services.forEach { it.destroy() }
        downloads.forEach { it.destroy() }
        activities.forEach { it.pause().stop().destroy() }
    }

    @Test fun headlessApplicationInitializationDoesNotStartKeepAliveOrRestoreDownloads() {
        app.downloadKeepAlive.dartReady()
        idle()
        assertNull(shadowOf(app).nextStartedService)
        assertFalse(keeper.running)
        assertFalse(app.downloadKeepAlive.recoveryExpected)
        assertTrue(commands.isEmpty())
    }

    @Test fun visibleAppStartsAnImmediateSilentStickyNotificationWithoutAWakeLock() {
        val service = start()
        assertTrue(keeper.running)
        val shadow = shadowOf(service)
        assertEquals(AppKeepAliveService.NOTIFICATION_ID, shadow.lastForegroundNotificationId)
        val notification = shadow.lastForegroundNotification
        assertEquals("文析助手", notification.extras.getString(Notification.EXTRA_TITLE))
        assertEquals("后台保活中 · 点击返回应用", notification.extras.getString(Notification.EXTRA_TEXT))
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(notification.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        assertEquals(Notification.CATEGORY_SERVICE, notification.category)
        assertEquals(MainActivity::class.java.name, shadowOf(notification.contentIntent).savedIntent.component!!.className)
        if (Build.VERSION.SDK_INT >= 34) {
            assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE, service.foregroundServiceType)
        }
        val channel = app.getSystemService(NotificationManager::class.java).getNotificationChannel(AppKeepAliveService.CHANNEL)
        assertEquals(NotificationManager.IMPORTANCE_LOW, channel.importance)
        assertNull(channel.sound)
        assertFalse(channel.shouldVibrate())
        assertFalse(channel.canShowBadge())
        assertNull(ShadowPowerManager.getLatestWakeLock())
        assertFalse(app.downloadKeepAlive.running)
        assertFalse(app.downloadKeepAlive.recoveryExpected)
    }

    @Test fun repeatedForegroundEntriesReuseTheServiceAndNotification() {
        val activity = activity()
        repeat(3) { keeper.appVisible(activity) }
        assertEquals(AppKeepAliveService::class.java.name, shadowOf(app).nextStartedService.component!!.className)
        assertNull(shadowOf(app).nextStartedService)
        service().onStartCommand(Intent(), 0, 1)
        repeat(4) { keeper.appVisible(activity) }
        assertNull(shadowOf(app).nextStartedService)
        assertTrue(keeper.running)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(9))
        assertTrue(errors.isEmpty())
    }

    @Test fun finishingActivityCannotStartAServiceOrAskForPermission() {
        val activity = activity()
        activity.finish()
        keeper.appVisible(activity)
        assertNull(shadowOf(app).nextStartedService)
        assertNull(shadowOf(activity).lastRequestedPermission)
        assertFalse(keeper.running)
    }

    @Test fun endingDownloadsReleasesTheirLockButKeepsStartupNotification() {
        val startup = start()
        app.downloadKeepAlive.update(DownloadNotice(1, "下载中", 20), Reply())
        val download = Robolectric.buildService(FlutterDownloadService::class.java)
            .also { downloads.add(it); it.create() }.get()
        assertEquals(Service.START_STICKY, download.onStartCommand(Intent(), 0, 1))
        assertTrue(download.wakeLockHeld)
        app.downloadKeepAlive.update(DownloadNotice.IDLE, Reply())
        assertFalse(download.wakeLockHeld)
        assertFalse(app.downloadKeepAlive.running)
        assertTrue(keeper.running)
        assertFalse(shadowOf(startup).isForegroundStopped)
        assertNotEquals(shadowOf(startup).lastForegroundNotificationId, shadowOf(download).lastForegroundNotificationId)
    }

    @Test fun notificationPauseDoesNotStopTheStartupService() {
        val startup = start()
        app.downloadKeepAlive.dartReady()
        app.downloadKeepAlive.update(DownloadNotice(1, "下载中"), Reply())
        val download = Robolectric.buildService(FlutterDownloadService::class.java)
            .also { downloads.add(it); it.create() }.get()
        download.onStartCommand(Intent(), 0, 1)
        download.onStartCommand(Intent().setAction("pauseAll"), 0, 2)
        idle()
        assertEquals(listOf("pauseAll"), commands)
        assertFalse(download.wakeLockHeld)
        assertTrue(keeper.running)
        assertFalse(shadowOf(startup).isForegroundStopped)
    }

    @Test fun stickyRecreationRestoresOnlyTheIdleService() {
        start()
        services.last().destroy()
        services.clear()
        newKeeper()
        val recreated = service()
        assertEquals(Service.START_STICKY, recreated.onStartCommand(null, 0, 2))
        app.downloadKeepAlive.dartReady()
        idle()
        assertTrue(keeper.running)
        assertFalse(app.downloadKeepAlive.recoveryExpected)
        assertTrue(commands.isEmpty())
        assertNull(ShadowPowerManager.getLatestWakeLock())
    }

    @Test fun coldUiLaunchStillDiscardsOldDownloadRecoveryBeforeStartingKeepAlive() {
        app.getSharedPreferences("download_keepalive", Context.MODE_PRIVATE).edit().putBoolean("wanted", true).commit()
        app.downloadKeepAlive.appVisible()
        start()
        app.downloadKeepAlive.dartReady()
        idle()
        assertEquals(listOf("downloadDiscardRecovery"), commands)
        assertFalse(app.downloadKeepAlive.recoveryExpected)
        assertTrue(keeper.running)
    }

    @Test fun stoppedSessionsCannotResurrectFromANullIntent() {
        val current = start()
        keeper.stop()
        assertFalse(keeper.running)
        assertTrue(shadowOf(current).isForegroundStopped)
        assertTrue(shadowOf(current).isStoppedBySelf)
        newKeeper()
        assertEquals(Service.START_NOT_STICKY, service().onStartCommand(null, 0, 2))
        assertFalse(keeper.running)
    }

    @Test fun foregroundRejectionIsReportedAndDoesNotClaimRunningOrScheduleARetryLoop() {
        keeper.appVisible(activity())
        val denied = service()
        shadowOf(denied).setThrowInStartForeground(SecurityException("FGS rejected"))
        assertEquals(Service.START_NOT_STICKY, denied.onStartCommand(Intent(), 0, 1))
        assertFalse(keeper.running)
        assertEquals(listOf("keepalive.foreground_failed"), errors)
        assertTrue(shadowOf(denied).isStoppedBySelf)
        assertNotNull(shadowOf(app).nextStartedService)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(1))
        assertNull(shadowOf(app).nextStartedService)
        assertEquals(Service.START_NOT_STICKY, service().onStartCommand(null, 0, 2))
    }

    @Test fun stalledStartupHasABoundedTimeoutAndCanRetryOnTheNextVisibleEntry() {
        val activity = activity()
        keeper.appVisible(activity)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(8))
        assertFalse(keeper.running)
        assertEquals(listOf("keepalive.foreground_failed"), errors)
        keeper.appVisible(activity)
        assertEquals(Service.START_STICKY, service().onStartCommand(Intent(), 0, 2))
        assertTrue(keeper.running)
    }

    @Test fun systemTimeoutStopsRatherThanRestartingInTheBackground() {
        val service = start()
        assertNotNull(shadowOf(app).nextStartedService)
        service.onTimeout(1, 0)
        assertFalse(keeper.running)
        assertTrue(shadowOf(service).isForegroundStopped)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMinutes(1))
        assertNull(shadowOf(app).nextStartedService)
        assertEquals(Service.START_NOT_STICKY, service().onStartCommand(null, 0, 2))
    }

    @Config(sdk = [35])
    @Test fun notificationDenialDoesNotBlockTheServiceAndPermissionIsAskedOnlyOnce() {
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val activity = activity()
        keeper.appVisible(activity)
        val request = shadowOf(activity).lastRequestedPermission
        assertEquals(NotificationPermission.REQUEST_CODE, request.requestCode)
        assertArrayEquals(arrayOf(Manifest.permission.POST_NOTIFICATIONS), request.requestedPermissions)
        val service = service()
        assertEquals(Service.START_STICKY, service.onStartCommand(Intent(), 0, 1))
        assertTrue(keeper.running)
        val returned = activity()
        keeper.appVisible(returned)
        NotificationPermission.requestOnce(returned) // Same path used by downloads.
        assertNull(shadowOf(returned).lastRequestedPermission)
        shadowOf(app).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        keeper.refresh()
        assertNotNull(shadowOf(app.getSystemService(NotificationManager::class.java)).getNotification(AppKeepAliveService.NOTIFICATION_ID))
        assertTrue(keeper.running)
    }

    @Config(sdk = [35])
    @Test fun previousVersionPermissionChoiceIsRespectedDuringStartup() {
        shadowOf(app).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        app.getSharedPreferences("asterlink_flutter_permissions", Context.MODE_PRIVATE).edit().putBoolean("notificationsAsked", true).commit()
        val activity = activity()
        keeper.appVisible(activity)
        assertNull(shadowOf(activity).lastRequestedPermission)
        assertEquals(Service.START_STICKY, service().onStartCommand(Intent(), 0, 1))
    }

    @Test fun protectionStatusDistinguishesIdleKeepAliveFromDownloadAndChannelState() {
        start()
        val manager = app.getSystemService(NotificationManager::class.java)
        val notifications = shadowOf(manager)
        notifications.setNotificationsEnabled(true)
        manager.createNotificationChannel(NotificationChannel(AppKeepAliveService.CHANNEL, "后台保活", NotificationManager.IMPORTANCE_NONE))
        val protection = DownloadProtection(app, app.downloadKeepAlive)
        val status = protection.status()
        assertEquals(true, status["keepAliveRunning"])
        assertEquals(false, status["serviceRunning"])
        assertEquals(false, status["wakeLockHeld"])
        assertEquals(false, status["keepAliveNotificationsEnabled"])
        assertEquals(true, status["notificationsEnabled"])
        val activity = activity()
        protection.open("notifications", activity)
        val settings = shadowOf(activity).nextStartedActivity
        assertEquals(Settings.ACTION_APP_NOTIFICATION_SETTINGS, settings.action)
        assertEquals(app.packageName, settings.getStringExtra(Settings.EXTRA_APP_PACKAGE))
    }
}
