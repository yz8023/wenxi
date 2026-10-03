package com.asterlink.app.metrics

import android.app.Activity
import android.content.Context
import com.umeng.analytics.MobclickAgent
import com.umeng.commonsdk.UMConfigure

internal class AndroidMetricsBackend(private val context: Context) : MetricsBackend {
    override fun preInit() {
        UMConfigure.preInit(context, null, null)
    }

    override fun initialize() {
        UMConfigure.setLogEnabled(false)
        UMConfigure.enableImeiCollection(false)
        UMConfigure.enableImsiCollection(false)
        UMConfigure.enableIccidCollection(false)
        UMConfigure.enableWiFiMacCollection(false)
        UMConfigure.enableAplCollection(false)
        MobclickAgent.setCatchUncaughtExceptions(false)
        MobclickAgent.setPageCollectionMode(MobclickAgent.PageMode.LEGACY_AUTO)
        UMConfigure.submitPolicyGrantResult(context, true)
        UMConfigure.init(context, UMConfigure.DEVICE_TYPE_PHONE, null)
        check(UMConfigure.getInitStatus()) { "Usage metrics initialization did not complete" }
    }

    override fun resume(activity: Activity) = MobclickAgent.onResume(activity)
    override fun pause(activity: Activity) = MobclickAgent.onPause(activity)
    override fun disable() = MobclickAgent.disable()
}
