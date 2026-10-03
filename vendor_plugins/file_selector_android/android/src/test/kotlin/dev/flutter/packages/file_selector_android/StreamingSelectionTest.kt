package dev.flutter.packages.file_selector_android

import android.app.Activity
import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.database.MatrixCursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.mockito.ArgumentMatchers.*
import org.mockito.Mockito.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class StreamingSelectionTest {
  @get:Rule val temp = TemporaryFolder()
  private lateinit var context: Context
  private lateinit var resolver: ContentResolver
  private val uri = Uri.parse("content://fixture/selected")

  @Before fun setup() {
    context = mock(Context::class.java)
    resolver = mock(ContentResolver::class.java)
    `when`(context.contentResolver).thenReturn(resolver)
    `when`(context.cacheDir).thenReturn(temp.root)
    `when`(resolver.getType(uri)).thenReturn("application/octet-stream")
    // No SIZE column: providers may omit it or report a value larger than Int.MAX_VALUE.
    `when`(resolver.query(eq(uri), any(), isNull(), isNull(), isNull())).thenAnswer {
      MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply { addRow(arrayOf("original.apk")) }
    }
  }

  @Test fun copiesInBoundedChunksWithoutRenamingOriginalExtension() {
    var remaining = 3L * 1024 * 1024 + 9
    var largestRequest = 0
    val source = object : InputStream() {
      override fun read(): Int = throw AssertionError("Use bounded bulk reads")
      override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        largestRequest = maxOf(largestRequest, length)
        if (remaining == 0L) return -1
        val count = minOf(remaining, length.toLong()).toInt()
        buffer.fill(7, offset, offset + count)
        remaining -= count
        return count
      }
    }
    `when`(resolver.openInputStream(uri)).thenReturn(source)
    val copied = File(FileUtils.getPathFromCopyOfFileFromUri(context, uri))
    assertEquals("original.apk", copied.name)
    assertEquals(3L * 1024 * 1024 + 9, copied.length())
    assertTrue(largestRequest <= 64 * 1024)
    assertEquals(0L, remaining)
  }

  @Test fun nativeResponseContainsDiskPathAndNoFileBytes() {
    `when`(resolver.openInputStream(uri)).thenAnswer { ByteArrayInputStream(byteArrayOf(1, 2, 3)) }
    val binding = mock(ActivityPluginBinding::class.java)
    val response = FileSelectorApiImpl(binding).toFileResponse(context, uri)!!
    assertEquals(3L, response.size)
    assertEquals(0, response.bytes.size)
    assertArrayEquals(byteArrayOf(1, 2, 3), File(response.path).readBytes())
    val next = FileSelectorApiImpl(binding).toFileResponse(context, uri)!!
    assertNotEquals(response.path, next.path)
  }

  @Test fun largeSelectionKeepsPlatformMessageSmall() {
    val size = 240L * 1024 * 1024 + 9
    var remaining = size
    `when`(resolver.openInputStream(uri)).thenReturn(object : InputStream() {
      override fun read(): Int = throw AssertionError("Use bounded bulk reads")
      override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        assertTrue(length <= 64 * 1024)
        if (remaining == 0L) return -1
        val count = minOf(remaining, length.toLong()).toInt()
        buffer.fill(7, offset, offset + count)
        remaining -= count
        return count
      }
    })
    val response = FileSelectorApiImpl(mock(ActivityPluginBinding::class.java)).toFileResponse(context, uri)!!
    assertEquals(size, response.size)
    assertEquals(size, File(response.path).length())
    assertEquals(0, response.bytes.size)
    val message = FileSelectorApi.codec.encodeMessage(listOf(listOf(response)))!!
    assertTrue(message.position() < 4096)
    assertEquals(0L, remaining)
  }

  @Test fun nullStreamFailsNormallyWithoutLeavingCacheFiles() {
    `when`(resolver.openInputStream(uri)).thenReturn(null)
    assertThrows(IOException::class.java) { FileUtils.getPathFromCopyOfFileFromUri(context, uri) }
    assertEquals(0, temp.root.listFiles()!!.size)
  }

  @Test fun revokedPermissionFailsNormallyWithoutLeavingCacheFiles() {
    `when`(resolver.openInputStream(uri)).thenThrow(SecurityException("revoked"))
    assertThrows(SecurityException::class.java) { FileUtils.getPathFromCopyOfFileFromUri(context, uri) }
    assertEquals(0, temp.root.listFiles()!!.size)
  }

  @Test fun failureDuringReadRemovesPartialCopy() {
    `when`(resolver.openInputStream(uri)).thenReturn(object : InputStream() {
      override fun read(): Int = throw IOException("provider disconnected")
    })
    assertThrows(IOException::class.java) { FileUtils.getPathFromCopyOfFileFromUri(context, uri) }
    assertEquals(0, temp.root.listFiles()!!.size)
  }

  @Test fun failureWhenClosingInputAlsoRemovesCopy() {
    `when`(resolver.openInputStream(uri)).thenReturn(object : ByteArrayInputStream(byteArrayOf(1)) {
      override fun close() { throw IOException("provider close failed") }
    })
    assertThrows(IOException::class.java) { FileUtils.getPathFromCopyOfFileFromUri(context, uri) }
    assertEquals(0, temp.root.listFiles()!!.size)
  }

  @Test fun activityResultIsReadInBackgroundAndDuplicateUrisCompleteOnce() {
    val binding = mock(ActivityPluginBinding::class.java)
    val activity = mock(Activity::class.java)
    `when`(binding.activity).thenReturn(activity)
    `when`(activity.applicationContext).thenReturn(context)
    `when`(resolver.openInputStream(uri)).thenAnswer { ByteArrayInputStream(byteArrayOf(9)) }
    var worker: Runnable? = null
    val factory = object : FileSelectorApiImpl.NativeObjectFactory() {
      override fun runInBackground(action: Runnable) { worker = action }
      override fun onMainThread(action: Runnable) { action.run() }
    }
    val api = FileSelectorApiImpl(binding, factory) { true }
    var listener: PluginRegistry.ActivityResultListener? = null
    doAnswer { listener = it.getArgument(0); null }.`when`(binding).addActivityResultListener(any())
    var calls = 0
    var returned: List<FileResponse>? = null
    api.openFiles(null, FileTypes(emptyList(), emptyList())) {
      calls++
      returned = it.getOrThrow()
    }
    val data = Intent().setData(uri).apply { clipData = ClipData.newRawUri("file", uri) }
    assertTrue(listener!!.onActivityResult(222, Activity.RESULT_OK, data))
    assertEquals(0, calls)
    verify(resolver, never()).openInputStream(uri)
    assertFalse(listener!!.onActivityResult(222, Activity.RESULT_OK, data))
    worker!!.run()
    assertEquals(1, calls)
    assertEquals(1, returned!!.size)
    verify(binding).removeActivityResultListener(listener!!)
  }

  @Test fun unreadableSelectionReturnsErrorThroughCallback() {
    val binding = mock(ActivityPluginBinding::class.java)
    val activity = mock(Activity::class.java)
    `when`(binding.activity).thenReturn(activity)
    `when`(activity.applicationContext).thenReturn(context)
    val factory = object : FileSelectorApiImpl.NativeObjectFactory() {
      override fun runInBackground(action: Runnable) { action.run() }
      override fun onMainThread(action: Runnable) { action.run() }
    }
    var listener: PluginRegistry.ActivityResultListener? = null
    doAnswer { listener = it.getArgument(0); null }.`when`(binding).addActivityResultListener(any())
    var failure: Throwable? = null
    FileSelectorApiImpl(binding, factory) { true }.openFile(null, FileTypes(emptyList(), emptyList())) {
      failure = it.exceptionOrNull()
    }
    listener!!.onActivityResult(221, Activity.RESULT_OK, Intent().setData(uri))
    assertTrue(failure is IOException)
  }
}
