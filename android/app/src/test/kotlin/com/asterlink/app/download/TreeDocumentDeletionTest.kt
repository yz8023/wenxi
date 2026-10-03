package com.asterlink.app.download

import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.content.pm.ResolveInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
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
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], manifest = Config.NONE)
class TreeDocumentDeletionTest {
    private lateinit var saver: DownloadFileSaver
    private lateinit var provider: StorageDocuments
    private lateinit var root: File
    private lateinit var file: File
    private lateinit var tree: Uri
    private lateinit var uri: Uri

    @Before fun setup() {
        val context = RuntimeEnvironment.getApplication() as Context
        root = File(context.filesDir, "Downloads").apply { mkdirs() }
        file = File(root, "sub/file.bin").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(1)) }
        val info = ProviderInfo().apply {
            authority = "com.android.externalstorage.documents"
            name = StorageDocuments::class.java.name
            packageName = context.packageName
            applicationInfo = context.applicationInfo
            exported = true
            grantUriPermissions = true
            readPermission = "android.permission.MANAGE_DOCUMENTS"
            writePermission = readPermission
        }
        provider = StorageDocuments().apply { directory = root; attachInfo(context, info) }
        ShadowContentResolver.registerProviderInternal(info.authority, provider)
        Shadows.shadowOf(context.packageManager).addResolveInfoForIntent(
            Intent(DocumentsContract.PROVIDER_INTERFACE), ResolveInfo().apply { providerInfo = info })
        tree = DocumentsContract.buildTreeDocumentUri(info.authority, "primary:Downloads")
        uri = DocumentsContract.buildDocumentUriUsingTree(tree, "primary:Downloads/sub/file.bin")
        saver = DownloadFileSaver(context)
    }

    @Test fun externallyRemovedFileCanBeRemovedFromDownloadRecords() {
        assertEquals("present", saver.availability(uri.toString()))
        assertTrue(file.delete())
        assertEquals("missing", saver.availability(uri.toString()))
        saver.deleteOrThrow(uri.toString())
        saver.deleteOrThrow(uri.toString())
        assertEquals(0, provider.deletes)
    }

    @Test fun externallyRemovedParentDirectoryConfirmsMissingDescendant() {
        assertTrue(file.delete())
        assertTrue(file.parentFile!!.delete())
        assertEquals("missing", saver.availability(uri.toString()))
        saver.deleteOrThrow(uri.toString())
    }

    @Test fun existingFileCanBeDeletedAndRepeatedDeletionSucceeds() {
        saver.deleteOrThrow(uri.toString())
        assertFalse(file.exists())
        saver.deleteOrThrow(uri.toString())
        assertEquals(1, provider.deletes)
    }

    @Test fun deletionRaceAfterProviderRemovesFileIsSuccessful() {
        provider.throwAfterDelete = true
        saver.deleteOrThrow(uri.toString())
        assertFalse(file.exists())
        assertEquals(1, provider.deletes)
    }

    @Test fun revokedGrantDoesNotConfirmMissing() {
        assertTrue(file.delete())
        provider.denied = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
    }

    @Test fun nullListingDoesNotConfirmMissing() {
        assertTrue(file.delete())
        provider.nullListing = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
    }

    @Test fun loadingOrFailedListingDoesNotConfirmMissing() {
        assertTrue(file.delete())
        provider.loading = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
        provider.loading = false
        provider.listError = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
    }

    @Test fun missingDocumentIdColumnDoesNotConfirmMissing() {
        assertTrue(file.delete())
        provider.invalidColumns = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
    }

    @Test fun mountedRootDisappearingIsNotTreatedAsDeletedFile() {
        assertTrue(file.delete())
        assertTrue(file.parentFile!!.delete())
        assertTrue(root.delete())
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
    }

    @Test fun existingButUnreadableDocumentIsRetained() {
        provider.unreadable = true
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(Exception::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.exists())
    }

    @Test fun directoryReplacingFileIsNeverDeleted() {
        assertTrue(file.delete())
        assertTrue(file.mkdir())
        assertEquals("inaccessible", saver.availability(uri.toString()))
        assertThrows(IOException::class.java) { saver.deleteOrThrow(uri.toString()) }
        assertTrue(file.isDirectory)
        assertEquals(0, provider.deletes)
    }

    @Test fun malformedOrOutsideTreeIdsAreRetainedWithoutListing() {
        for (id in listOf("primary:Other/missing.bin", "primary:Downloads/../Other/missing.bin", "secondary:Downloads/missing.bin")) {
            val invalid = DocumentsContract.buildDocumentUriUsingTree(tree, id).toString()
            assertEquals("inaccessible", saver.availability(invalid))
            assertThrows(Exception::class.java) { saver.deleteOrThrow(invalid) }
        }
        assertEquals(0, provider.listings)
    }

    class StorageDocuments : DocumentsProvider() {
        lateinit var directory: File
        var denied = false
        var unreadable = false
        var nullListing = false
        var invalidColumns = false
        var loading = false
        var listError = false
        var throwAfterDelete = false
        var deletes = 0
        var listings = 0
        override fun onCreate() = true
        private fun path(id: String): File {
            if (denied) throw SecurityException("grant revoked")
            if (id != "primary:Downloads" && !id.startsWith("primary:Downloads/")) throw SecurityException("outside tree")
            val result = if (id == "primary:Downloads") directory else File(directory, id.removePrefix("primary:Downloads/"))
            if (result.canonicalPath != directory.canonicalPath && !result.canonicalPath.startsWith(directory.canonicalPath + File.separator))
                throw SecurityException("outside tree")
            if (!result.exists()) throw FileNotFoundException("Missing file for $id")
            return result
        }
        override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
            try {
                val parent = path(parentDocumentId)
                val child = path(documentId)
                return child.canonicalPath.startsWith(parent.canonicalPath + File.separator)
            } catch (error: IOException) {
                // FileSystemProvider loses the exception cause, retaining only its text.
                throw IllegalArgumentException("Failed to determine if $documentId is child of $parentDocumentId: $error")
            }
        }
        override fun queryRoots(projection: Array<out String>?): Cursor =
            MatrixCursor(arrayOf(DocumentsContract.Root.COLUMN_ROOT_ID))
        override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
            val target = path(documentId)
            return MatrixCursor(arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE)).apply {
                addRow(arrayOf(documentId, target.name, if (target.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"))
            }
        }
        override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor? {
            listings++
            val parent = path(parentDocumentId)
            if (nullListing) return null
            if (invalidColumns) return MatrixCursor(arrayOf("invalid"))
            return MatrixCursor(arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID)).apply {
                parent.listFiles()!!.forEach { addRow(arrayOf("$parentDocumentId/${it.name}")) }
                extras = Bundle().apply {
                    putBoolean(DocumentsContract.EXTRA_LOADING, loading)
                    if (listError) putString(DocumentsContract.EXTRA_ERROR, "provider unavailable")
                }
            }
        }
        override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
            if (unreadable) throw IllegalArgumentException("provider unable to open document")
            return ParcelFileDescriptor.open(path(documentId), ParcelFileDescriptor.MODE_READ_ONLY)
        }
        override fun deleteDocument(documentId: String) {
            if (unreadable) throw IOException("provider unable to delete document")
            val target = path(documentId)
            deletes++
            check(target.delete())
            if (throwAfterDelete) throw IllegalArgumentException("document disappeared")
        }
    }
}
