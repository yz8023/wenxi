package com.asterlink.app.download

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.content.pm.ResolveInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.CancellationSignal
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.OsConstants
import android.system.StructStat
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.shadows.ShadowLinux

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
class DownloadFileSaverTest {
    private lateinit var saver: DownloadFileSaver
    private lateinit var provider: DownloadProvider
    private lateinit var file: File
    private val uri = Uri.parse("content://download.test/files/1")

    @Before
    fun setup() {
        val context = RuntimeEnvironment.getApplication() as Context
        saver = DownloadFileSaver(context)
        file = File(context.filesDir, "download.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        provider = DownloadProvider().apply {
            target = file
            attachInfo(context, ProviderInfo().apply { authority = "download.test" })
        }
        ShadowContentResolver.registerProviderInternal("download.test", provider)
    }

    @Test
    fun existingContentIsDeletedAndRepeatedDeletionSucceeds() {
        assertEquals("present", saver.availability(uri.toString()))
        saver.deleteOrThrow(uri.toString())
        assertFalse(file.exists())
        saver.deleteOrThrow(uri.toString())
        assertEquals("missing", saver.availability(uri.toString()))
        assertEquals(1, provider.deleteCalls)
    }

    @Test
    fun alreadyMissingContentDoesNotCallAnInvalidProviderDelete() {
        assertTrue(file.delete())
        provider.deleteError = IllegalArgumentException("unknown URI")
        assertEquals("missing", saver.availability(uri.toString()))
        saver.deleteOrThrow(uri.toString())
        assertEquals(0, provider.deleteCalls)
    }

    @Test
    fun deletionReturningZeroAfterRemovingTheFileSucceeds() {
        provider.resultAfterDelete = 0
        saver.deleteOrThrow(uri.toString())
        assertEquals(1, provider.deleteCalls)
        assertFalse(file.exists())
    }

    @Test
    fun deletionThrowingAfterRemovingTheFileSucceeds() {
        provider.errorAfterDelete = IllegalArgumentException("URI already removed")
        saver.deleteOrThrow(uri.toString())
        assertFalse(file.exists())
    }

    @Test
    fun providerCrashIsInaccessibleAndUnconfirmedDeletionFails() {
        provider.nullDescriptor = true
        provider.removeFile = false
        provider.resultAfterDelete = 0
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test
    fun lostUriGrantIsNotADeletedFile() {
        provider.openError = SecurityException("grant revoked")
        provider.deleteError = SecurityException("grant revoked")
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(SecurityException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test
    fun permissionFailureWrappedAsFileNotFoundMustNotBeSwallowed() {
        provider.openError = FileNotFoundException("open failed: EACCES (Permission denied)")
        provider.deleteError = FileNotFoundException("open failed: EACCES (Permission denied)")
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(FileNotFoundException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test
    fun unreadableContentWithMetadataIsRetained() {
        provider.openError = FileNotFoundException("cannot open document")
        provider.removeFile = false
        provider.resultAfterDelete = 0
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test
    fun nullMetadataDoesNotConfirmAbsence() {
        provider.openError = FileNotFoundException("cannot open document")
        provider.nullMetadata = true
        provider.removeFile = false
        provider.resultAfterDelete = 0
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test
    @Config(shadows = [MissingPathOs::class])
    fun legacyAbsolutePathsAndAbsentPathsCanBeDeleted() {
        assertEquals("present", saver.availability(file.absolutePath))
        saver.deleteOrThrow(file.absolutePath)
        assertFalse(file.exists())
        saver.deleteOrThrow(file.absolutePath)
        assertEquals("missing", saver.availability(file.absolutePath))
    }

    @Test
    fun aDirectoryReplacingAFileIsNeverDeleted() {
        assertTrue(file.delete())
        assertTrue(file.mkdir())
        assertEquals("inaccessible", saver.availability(file.absolutePath))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(file.absolutePath) }
        assertTrue(file.isDirectory)
        provider.mime = DocumentsContract.Document.MIME_TYPE_DIR
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertEquals(0, provider.deleteCalls)
    }

    @Test
    fun invalidRelativePathsAreRetained() {
        assertEquals("inaccessible", saver.availability("relative.bin"))
        assertThrows(IOException::class.java) { saver.deleteOrThrow("relative.bin") }
        assertTrue(file.exists())
    }

    private fun documents(): Pair<DownloadDocuments, Uri> {
        val context = RuntimeEnvironment.getApplication() as Context
        val info = ProviderInfo().apply {
            authority = "documents.test"
            name = DownloadDocuments::class.java.name
            packageName = context.packageName
            applicationInfo = context.applicationInfo
            exported = true
            grantUriPermissions = true
            readPermission = "android.permission.MANAGE_DOCUMENTS"
            writePermission = readPermission
        }
        val documents = DownloadDocuments().apply {
            target = file
            attachInfo(context, info)
        }
        ShadowContentResolver.registerProviderInternal(info.authority, documents)
        Shadows.shadowOf(context.packageManager).addResolveInfoForIntent(
            Intent(DocumentsContract.PROVIDER_INTERFACE), ResolveInfo().apply { providerInfo = info })
        val documentUri = DocumentsContract.buildDocumentUri(info.authority, "1")
        assertTrue(DocumentsContract.isDocumentUri(context, documentUri))
        return documents to documentUri
    }

    @Test
    fun missingSafDocumentWithNullMetadataCanBeRemoved() {
        val (documents, documentUri) = documents()
        assertTrue(file.delete())
        // Exercise DocumentsProvider's real conversion of not-found into null.
        val resolver = RuntimeEnvironment.getApplication().contentResolver
        assertNull(resolver.query(documentUri, null, Bundle.EMPTY, null))
        assertEquals("missing", saver.availability(documentUri.toString()))
        saver.deleteOrThrow(documentUri.toString())
        assertEquals(0, documents.deleteCalls)
    }

    @Test
    fun safDocumentCanBeDeletedAndDeletedAgain() {
        val (documents, documentUri) = documents()
        assertEquals("present", saver.availability(documentUri.toString()))
        saver.deleteOrThrow(documentUri.toString())
        assertFalse(file.exists())
        saver.deleteOrThrow(documentUri.toString())
        assertEquals(1, documents.deleteCalls)
    }

    @Test
    fun revokedSafPermissionNeverBecomesMissing() {
        val (documents, documentUri) = documents()
        documents.denied = true
        assertEquals("inaccessible", saver.availability(documentUri.toString()))
        // Older DocumentsContract versions can translate a denied operation to false.
        assertThrows(Exception::class.java) { saver.deleteOrThrow(documentUri.toString()) }
        assertTrue(file.exists())
    }

    // Robolectric 4.16.1 stat() returns a zero-mode StructStat for absent paths.
    // Match Android's ENOENT for this host-file test without weakening app checks.
    @Implements(android.system.Os::class)
    class MissingPathOs {
        companion object {
            @JvmStatic
            @Implementation
            fun stat(path: String): StructStat {
                if (!File(path).exists()) throw ErrnoException("stat", OsConstants.ENOENT)
                return ShadowLinux().stat(path)
            }
        }
    }

    class DownloadProvider : ContentProvider() {
        lateinit var target: File
        var openError: Exception? = null
        var deleteError: Exception? = null
        var errorAfterDelete: Exception? = null
        var nullDescriptor = false
        var nullMetadata = false
        var removeFile = true
        var resultAfterDelete = 1
        var deleteCalls = 0
        var mime = "application/octet-stream"
        override fun onCreate() = true
        override fun getType(uri: Uri) = mime
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            if (nullMetadata) return null
            return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME)).apply {
                if (target.exists()) addRow(arrayOf(target.name))
            }
        }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            openError?.let { throw it }
            if (nullDescriptor) return null
            if (!target.exists()) throw FileNotFoundException("document missing")
            return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
            deleteCalls++
            deleteError?.let { throw it }
            if (removeFile) target.delete()
            errorAfterDelete?.let { throw it }
            return resultAfterDelete
        }
    }

    class DownloadDocuments : DocumentsProvider() {
        lateinit var target: File
        var denied = false
        var deleteCalls = 0
        override fun onCreate() = true
        private fun checkFile() {
            if (denied) throw SecurityException("grant revoked")
            if (!target.exists()) throw FileNotFoundException("document missing")
        }
        override fun queryRoots(projection: Array<out String>?): Cursor =
            MatrixCursor(arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID))
        override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
            checkFile()
            return MatrixCursor(arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_FLAGS,
            )).apply {
                addRow(arrayOf(documentId, target.name, "application/octet-stream", DocumentsContract.Document.FLAG_SUPPORTS_DELETE))
            }
        }
        override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor =
            MatrixCursor(arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID))
        override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
            checkFile()
            return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun deleteDocument(documentId: String) {
            checkFile()
            deleteCalls++
            check(target.delete())
        }
    }
}
