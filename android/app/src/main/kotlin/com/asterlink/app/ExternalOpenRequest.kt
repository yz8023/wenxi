package com.asterlink.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import java.io.File
import java.util.ArrayDeque
import java.util.Locale

class ExternalOpenRequest(private val context: Context) {
    /** Called on the intake worker: querying an external document provider must not block the UI. */
    fun parse(intent: Intent): Map<String, Any>? {
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_SEND) return null
        return try {
            val mime = intent.type.orEmpty().substringBefore(';').lowercase(Locale.ROOT)
            val player = intent.component?.className == "${context.packageName}.PlayerEntry"
            if (intent.action == Intent.ACTION_SEND && !player && mime.startsWith("text/")) {
                val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim().orEmpty()
                if (text.isBlank() || text.length > MAX_TEXT) invalid("外部应用没有提供有效的下载链接")
                else mapOf("kind" to "share", "text" to text, "name" to name(intent, null), "headers" to headers(intent))
            } else {
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                val uri = intent.data ?: stream ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                    ?: return invalid("外部应用没有提供文件或播放地址")
                val scheme = uri.scheme?.lowercase(Locale.ROOT)
                val isPlayer = player || (intent.component?.className != "${context.packageName}.DownloadEntry" &&
                    (mime.startsWith("video/") || mime in STREAM_TYPES))
                if (scheme == "magnet" && !isPlayer) {
                    if (uri.toString().length > MAX_URI) invalid("外部链接过长")
                    else mapOf("kind" to "share", "text" to uri.toString())
                } else if (!validUri(uri, isPlayer)) {
                    invalid(if (isPlayer) "不支持此外部播放地址，请提供 HTTP、HTTPS 或可读取的视频文件" else "下载器需要 HTTP 或 HTTPS 链接")
                } else {
                    mapOf(
                        "kind" to if (isPlayer) "play" else "download",
                        "uri" to uri.toString(),
                        "name" to name(intent, uri),
                        "mime" to mime,
                        "headers" to if (scheme == "http" || scheme == "https") headers(intent) else emptyMap<String, String>(),
                    )
                }
            }
        } catch (_: Exception) {
            invalid("无法读取外部应用传来的文件信息，请重新选择文件")
        }
    }

    private fun validUri(uri: Uri, player: Boolean): Boolean {
        val value = uri.toString()
        if (value.length > MAX_URI || value.any { it <= '\u0020' || it == '\u007f' }) return false
        return when (uri.scheme?.lowercase(Locale.ROOT)) {
            "http", "https" -> !uri.host.isNullOrBlank() && uri.userInfo.isNullOrEmpty()
            "content" -> player && !uri.authority.isNullOrBlank() && uri.authority != "${context.packageName}.files"
            "file" -> {
                val path = uri.path ?: return false
                val canonical = File(path).canonicalPath
                player && uri.authority.isNullOrEmpty() &&
                    (canonical.startsWith("/storage/") || canonical.startsWith("/sdcard/"))
            }
            else -> false
        }
    }

    private fun name(intent: Intent, uri: Uri?): String {
        for (key in listOf(Intent.EXTRA_TITLE, "title", "filename", "fileName", "name")) {
            val text = intent.getCharSequenceExtra(key)?.toString()?.trim()
            if (!text.isNullOrBlank()) return text.take(255)
        }
        if (uri?.scheme == "content") {
            runCatching {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0) cursor.getString(index)?.takeIf { it.isNotBlank() }?.let { return it.take(255) }
                    }
                }
            }
        }
        return uri?.lastPathSegment?.take(255).orEmpty()
    }

    private fun headers(intent: Intent): Map<String, String> {
        val values = linkedMapOf<String, String>()
        var bytes = 0
        fun put(key: String, value: String) {
            val normalized = key.lowercase(Locale.ROOT)
            if (values.size >= 48 || key.length > 128 || !HEADER_NAME.matches(key) ||
                normalized in BLOCKED_HEADERS || value.length > 8192 ||
                value.any { it == '\r' || it == '\n' || it == '\u0000' } || bytes + key.length + value.length > 32768) return
            values.keys.firstOrNull { it.equals(key, ignoreCase = true) }?.let(values::remove)
            values[key] = value
            bytes += key.length + value.length
        }
        for (key in listOf("headers", "android.media.intent.extra.HTTP_HEADERS", "com.android.browser.headers")) {
            @Suppress("DEPRECATION")
            when (val raw = intent.extras?.get(key)) {
                is Bundle -> for (entry in raw.keySet()) {
                    @Suppress("DEPRECATION")
                    (raw.get(entry) as? String)?.let { put(entry, it) }
                }
                is Array<*> -> raw.toList().chunked(2).forEach { pair ->
                    if (pair.size == 2 && pair[0] is String && pair[1] is String) put(pair[0] as String, pair[1] as String)
                }
                is ArrayList<*> -> raw.chunked(2).forEach { pair ->
                    if (pair.size == 2 && pair[0] is String && pair[1] is String) put(pair[0] as String, pair[1] as String)
                }
            }
        }
        for ((key, header) in mapOf("userAgent" to "User-Agent", "user-agent" to "User-Agent", "User-Agent" to "User-Agent",
            "referer" to "Referer", "referrer" to "Referer", "Referer" to "Referer", "cookie" to "Cookie", "Cookie" to "Cookie")) {
            intent.getStringExtra(key)?.let { put(header, it) }
        }
        return values
    }

    companion object {
        private const val MAX_URI = 16384
        private const val MAX_TEXT = 65536
        private val HEADER_NAME = Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
        private val BLOCKED_HEADERS = setOf("host", "connection", "content-length", "transfer-encoding", "range", "accept-encoding")
        private val STREAM_TYPES = setOf("application/x-mpegurl", "application/vnd.apple.mpegurl", "application/dash+xml", "application/mp4", "application/x-matroska")
        fun invalid(message: String): Map<String, Any> = mapOf("kind" to "error", "message" to message)
    }
}

/** Events only announce availability; a single drain delivers each request once. */
class ExternalOpenQueue {
    private val pending = ArrayDeque<Map<String, Any>>()
    private val seen = linkedSetOf<String>()

    @Synchronized fun offer(id: String, request: Map<String, Any>): Boolean {
        if (!seen.add(id)) return false
        if (seen.size > 64) seen.remove(seen.first())
        if (pending.size >= 16) pending.removeFirst()
        pending.addLast(request + ("id" to id))
        return true
    }

    @Synchronized fun take(): List<Map<String, Any>> = pending.toList().also { pending.clear() }
}
