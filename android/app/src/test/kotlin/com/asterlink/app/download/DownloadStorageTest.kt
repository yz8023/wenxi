package com.asterlink.app.download

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class DownloadStorageTest {
    private val context get() = RuntimeEnvironment.getApplication() as Context
    private fun target(plan: Map<String, Any>) = plan["target"] as Map<*, *>

    @Test fun primaryDocumentAndInternalCacheShareBudget() {
        val storage = DownloadStorage(context)
        val uri = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "primary:Download")
        val plan = storage.plan(context.cacheDir, uri.toString())
        assertEquals((plan["cache"] as Map<*, *>)["volume"], target(plan)["volume"])
    }

    @Test fun removableDocumentHasSeparateVolume() {
        val storage = DownloadStorage(context)
        val uri = DocumentsContract.buildTreeDocumentUri("com.android.externalstorage.documents", "1234-ABCD:Movies")
        val plan = storage.plan(context.cacheDir, uri.toString())
        assertEquals("volume:1234-abcd", target(plan)["volume"])
        assertNotEquals((plan["cache"] as Map<*, *>)["volume"], target(plan)["volume"])
    }

    @Test fun unknownProviderDoesNotPretendToExposeCacheCapacity() {
        val storage = DownloadStorage(context)
        val uri = Uri.parse("content://fixture.documents/tree/remote")
        val plan = storage.plan(context.cacheDir, uri.toString())
        assertNotEquals((plan["cache"] as Map<*, *>)["volume"], target(plan)["volume"])
        assertEquals(-1L, storage.freeBytes(uri.toString()))
    }
}
