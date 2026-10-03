package com.asterlink.app.metrics

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE, application = Application::class)
class UsageMetricsTest {
    private lateinit var context: Context

    private class FakeSdk : MetricsBackend {
        val calls = mutableListOf<String>()
        val resumed = mutableListOf<Activity>()
        val paused = mutableListOf<Activity>()
        var failPreInit = false
        var failInit = false
        override fun preInit() {
            calls.add("preInit")
            if (failPreInit) error("preInit unavailable")
        }
        override fun initialize() {
            calls.add("initialize")
            if (failInit) error("SDK unavailable")
        }
        override fun resume(activity: Activity) { calls.add("resume"); resumed.add(activity) }
        override fun pause(activity: Activity) { calls.add("pause"); paused.add(activity) }
        override fun disable() { calls.add("disable") }
    }

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences(UsageMetrics.PREFERENCES, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    private fun saveConsent(granted: Boolean, version: Int = UsageMetrics.POLICY_VERSION) {
        context.getSharedPreferences(UsageMetrics.PREFERENCES, Context.MODE_PRIVATE).edit()
            .putInt("policyVersion", version).putBoolean("granted", granted).commit()
    }

    private fun storageFailureContext() = object : ContextWrapper(context) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            val preferences = super.getSharedPreferences(name, mode)
            return object : SharedPreferences by preferences {
                override fun edit(): SharedPreferences.Editor {
                    val editor = preferences.edit()
                    return object : SharedPreferences.Editor by editor {
                        override fun putInt(key: String, value: Int): SharedPreferences.Editor {
                            editor.putInt(key, value)
                            return this
                        }
                        override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor {
                            editor.putBoolean(key, value)
                            return this
                        }
                        override fun commit() = false
                    }
                }
            }
        }
    }

    @Test fun firstLaunchEnablesStatisticsWithoutSavingAnExplicitChoice() {
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        val activity = Activity()
        analytics.start()
        analytics.resume(activity)
        analytics.pause(activity)
        assertEquals(true, analytics.status()["consent"])
        assertEquals(true, analytics.status()["initialized"])
        assertFalse(context.getSharedPreferences(UsageMetrics.PREFERENCES, Context.MODE_PRIVATE)
            .contains("granted"))
        assertEquals(listOf("preInit", "initialize", "resume", "pause"), sdk.calls)
    }

    @Test fun agreeingAfterFirstResumeStartsThatSessionExactlyOnce() {
        saveConsent(false)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        val activity = Activity()
        analytics.start()
        analytics.resume(activity)
        analytics.setConsent(true)
        analytics.setConsent(true)
        analytics.resume(activity)
        analytics.start()
        assertEquals(listOf("preInit", "initialize", "resume"), sdk.calls)
        assertEquals(true, analytics.status()["initialized"])
    }

    @Test fun refusalPersistsAcrossProcessRecreationWithoutSdkInitialization() {
        val first = UsageMetrics(context, FakeSdk())
        first.start()
        first.setConsent(false)
        val sdk = FakeSdk()
        val next = UsageMetrics(context, sdk)
        next.start()
        next.resume(Activity())
        assertEquals(false, next.status()["consent"])
        assertEquals(listOf("preInit"), sdk.calls)
    }

    @Test fun savedConsentInitializesOnColdStartButBackgroundEngineHasNoSession() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        analytics.start()
        assertEquals(listOf("preInit", "initialize"), sdk.calls)
        analytics.resume(Activity())
        assertEquals("resume", sdk.calls.last())
    }

    @Test fun defaultInitializationWithoutAnActivityDoesNotStartAUsageSession() {
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        analytics.start()
        analytics.start()
        assertEquals(listOf("preInit", "initialize"), sdk.calls)
        assertTrue(sdk.resumed.isEmpty())
    }

    @Test fun downloadServiceLifetimeDoesNotExtendForegroundUsage() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        val activity = Activity()
        analytics.start()
        analytics.resume(activity)
        analytics.pause(activity)
        analytics.pause(activity)
        analytics.start()
        assertEquals(listOf("preInit", "initialize", "resume", "pause"), sdk.calls)
        analytics.resume(activity)
        analytics.pause(activity)
        assertEquals(2, sdk.resumed.size)
        assertEquals(2, sdk.paused.size)
    }

    @Test fun lateOldActivityCallbacksDoNotPauseTheReplacementActivity() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        val first = Activity()
        val second = Activity()
        analytics.start()
        analytics.resume(first)
        analytics.resume(second)
        analytics.pause(first)
        assertEquals(listOf(first), sdk.paused)
        analytics.pause(second)
        assertEquals(listOf(first, second), sdk.paused)
    }

    @Test fun withdrawalStopsNewRecordsAndPreventsInitializationOnNextLaunch() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        val activity = Activity()
        analytics.start()
        analytics.resume(activity)
        analytics.setConsent(false)
        analytics.pause(activity)
        analytics.resume(activity)
        analytics.setConsent(false)
        assertEquals(listOf("preInit", "initialize", "resume", "pause", "disable"), sdk.calls)
        assertEquals(false, analytics.status()["initialized"])
        assertEquals(true, analytics.status()["restartRequired"])
        val nextSdk = FakeSdk()
        UsageMetrics(context, nextSdk).start()
        assertEquals(listOf("preInit"), nextSdk.calls)
    }

    @Test fun reEnablingAfterDisableWaitsUntilANewProcess() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        analytics.start()
        analytics.setConsent(false)
        analytics.setConsent(true)
        analytics.resume(Activity())
        assertEquals(listOf("preInit", "initialize", "disable"), sdk.calls)
        assertEquals(true, analytics.status()["consent"])
        assertEquals(true, analytics.status()["restartRequired"])
        assertEquals(false, analytics.status()["initialized"])
        val nextSdk = FakeSdk()
        val next = UsageMetrics(context, nextSdk)
        next.start()
        assertEquals(listOf("preInit", "initialize"), nextSdk.calls)
        assertEquals(false, next.status()["restartRequired"])
    }

    @Test fun anOlderSavedOptOutIsNotOverriddenByTheNewDefault() {
        context.getSharedPreferences("umeng_analytics_consent", Context.MODE_PRIVATE).edit()
            .putInt("policyVersion", 0).putBoolean("granted", false).commit()
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        analytics.start()
        analytics.resume(Activity())
        assertEquals(false, analytics.status()["consent"])
        assertEquals(listOf("preInit"), sdk.calls)
    }

    @Test fun anOlderSavedOptInContinuesToInitializeOnStartup() {
        saveConsent(true, version = UsageMetrics.POLICY_VERSION - 1)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(context, sdk)
        analytics.start()
        assertEquals(true, analytics.status()["consent"])
        assertEquals(listOf("preInit", "initialize"), sdk.calls)
    }

    @Test fun initializationFailureDoesNotEscapeOrRepeatedlyInitializeAPartialSdk() {
        val sdk = FakeSdk().apply { failInit = true }
        val errors = mutableListOf<String>()
        val analytics = UsageMetrics(context, sdk) { step, _ -> errors.add(step) }
        analytics.start()
        analytics.resume(Activity())
        analytics.setConsent(true)
        analytics.setConsent(true)
        analytics.start()
        assertEquals(listOf("preInit", "initialize"), sdk.calls)
        assertEquals(listOf("analytics.initialize"), errors)
        assertEquals(false, analytics.status()["initialized"])
        assertEquals(true, analytics.status()["restartRequired"])
    }

    @Test fun preInitFailureCannotTriggerInitializationEvenWithSavedConsent() {
        saveConsent(true)
        val sdk = FakeSdk().apply { failPreInit = true }
        val errors = mutableListOf<String>()
        val analytics = UsageMetrics(context, sdk) { step, _ -> errors.add(step) }
        analytics.start()
        analytics.resume(Activity())
        analytics.setConsent(true)
        assertEquals(listOf("preInit"), sdk.calls)
        assertEquals(listOf("analytics.preinit"), errors)
        assertEquals(false, analytics.status()["initialized"])
    }

    @Test fun reEnablingAnExistingOptOutRequiresASuccessfullySavedChoice() {
        saveConsent(false)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(storageFailureContext(), sdk)
        analytics.start()
        analytics.resume(Activity())
        assertThrows(IllegalStateException::class.java) { analytics.setConsent(true) }
        assertEquals(false, analytics.status()["consent"])
        assertEquals(listOf("preInit"), sdk.calls)
    }

    @Test fun failedWithdrawalPersistenceStillStopsNewUsageInTheCurrentProcess() {
        saveConsent(true)
        val sdk = FakeSdk()
        val analytics = UsageMetrics(storageFailureContext(), sdk)
        val activity = Activity()
        analytics.start()
        analytics.resume(activity)
        assertThrows(IllegalStateException::class.java) { analytics.setConsent(false) }
        analytics.pause(activity)
        analytics.resume(activity)
        assertEquals(false, analytics.status()["consent"])
        assertEquals(listOf("preInit", "initialize", "resume", "pause", "disable"), sdk.calls)
    }
}
