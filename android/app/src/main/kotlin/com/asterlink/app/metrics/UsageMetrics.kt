package com.asterlink.app.metrics

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal class UsageMetrics(
    context: Context,
    private val sdk: MetricsBackend = AndroidMetricsBackend(context.applicationContext),
    private val reportError: (String, Throwable) -> Unit = { _, _ -> },
) {
    companion object {
        const val CHANNEL = "com.asterlink.app/analytics"
        const val PREFERENCES = "umeng_analytics_consent"
        const val POLICY_VERSION = 1
    }

    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private var consent = preferences.getBoolean("granted", true)
    private var prepared = false
    private var initializationAttempted = false
    private var initialized = false
    private var disabledForProcess = false
    private var resumedActivity: Activity? = null
    private var sessionActivity: Activity? = null

    fun start() {
        if (!prepared) prepared = sdkCall("preinit", sdk::preInit)
        initializeIfAllowed()
    }

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> result.success(status())
                    "setConsent" -> {
                        val granted = call.argument<Boolean>("granted")
                        if (granted == null) {
                            result.error("analytics_argument", "缺少统计授权选择", null)
                        } else {
                            result.success(setConsent(granted))
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                reportError("analytics.${call.method}", error)
                result.error("analytics_settings", "统计设置保存失败，请重试", null)
            }
        }
    }

    fun status(): Map<String, Any?> = mapOf(
        "consent" to consent,
        "initialized" to (initialized && !disabledForProcess && consent == true),
        "restartRequired" to (disabledForProcess || (consent == true && !initialized)),
    )

    fun setConsent(granted: Boolean): Map<String, Any?> {
        if (!granted) {
            sessionActivity?.let { activity ->
                sessionActivity = null
                sdkCall("pause") { sdk.pause(activity) }
            }
            consent = false
            if (initializationAttempted && !disabledForProcess) {
                disabledForProcess = true
                sessionActivity = null
                sdkCall("disable", sdk::disable)
            }
        }
        check(
            preferences.edit()
                .putInt("policyVersion", POLICY_VERSION)
                .putBoolean("granted", granted)
                .commit(),
        ) { "Unable to persist analytics consent" }
        consent = granted
        initializeIfAllowed()
        return status()
    }

    private fun initializeIfAllowed() {
        if (consent != true || !prepared || initializationAttempted || disabledForProcess) return
        initializationAttempted = true
        initialized = sdkCall("initialize", sdk::initialize)
        resumeSession()
    }

    fun resume(activity: Activity) {
        resumedActivity?.takeIf { it !== activity }?.let(::pause)
        resumedActivity = activity
        resumeSession()
    }

    fun pause(activity: Activity) {
        if (resumedActivity === activity) resumedActivity = null
        if (sessionActivity !== activity) return
        sessionActivity = null
        if (initialized && !disabledForProcess && consent == true) {
            sdkCall("pause") { sdk.pause(activity) }
        }
    }

    private fun resumeSession() {
        val activity = resumedActivity ?: return
        if (!initialized || disabledForProcess || consent != true || sessionActivity === activity) return
        if (sdkCall("resume") { sdk.resume(activity) }) sessionActivity = activity
    }

    private fun sdkCall(operation: String, action: () -> Unit): Boolean = try {
        action()
        true
    } catch (error: Throwable) {
        reportError("analytics.$operation", error)
        false
    }
}
