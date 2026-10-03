package com.asterlink.app.metrics

import android.app.Activity

internal interface MetricsBackend {
    fun preInit()
    fun initialize()
    fun resume(activity: Activity)
    fun pause(activity: Activity)
    fun disable()
}
