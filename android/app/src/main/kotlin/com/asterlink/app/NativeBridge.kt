package com.asterlink.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AtomicFile
import android.util.Base64
import com.asterlink.app.download.DownloadFileSaver
import com.asterlink.app.download.DownloadStorage
import com.asterlink.app.security.SecureVault
import com.asterlink.nativecore.gopeed.Gopeed
import go.Seq
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class NativeBridge(private val context: Context, engine: FlutterEngine) {
    var activity: Activity? = null
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.asterlink.app/native")
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newFixedThreadPool(3)
    private val nativeWorker = Executors.newSingleThreadExecutor()
    private val externalWorker = Executors.newSingleThreadExecutor()
    private val externalParser = ExternalOpenRequest(context)
    private val externalOpens = ExternalOpenQueue()
    val fileOpening = FileOpening(context, { activity })
    val externalPlayer = ExternalPlayerOpening(context, { activity }, fileOpening)
    private val saver = DownloadFileSaver(context)
    private val storage = DownloadStorage(context)
    private val vault = SecureVault(context)
    private val exports = ConcurrentHashMap<String, AtomicBoolean>()
    private val cache = File(context.externalCacheDir ?: context.cacheDir, "asterlink_downloads")
    private var nativeStarted = false
    private var picker: MethodChannel.Result? = null
    private var documentBytes: ByteArray? = null
    private val diagnostics get() = (context.applicationContext as AsterLinkHost).diagnostics
    val downloadKeepAlive = DownloadKeepAlive(context, { method, completion ->
        channel.invokeMethod(method, null, object : MethodChannel.Result {
            override fun success(result: Any?) = completion(true)
            override fun error(code: String, message: String?, details: Any?) = completion(false)
            override fun notImplemented() = completion(false)
        })
    }, { event, error -> diagnostics.record(event, error) })
    private val downloadProtection = DownloadProtection(context, downloadKeepAlive)
    val downloadOverlay = DownloadOverlay(context, { activity }, { action, id, completion ->
        channel.invokeMethod("downloadOverlayAction", mapOf("action" to action, "id" to id), object : MethodChannel.Result {
            override fun success(result: Any?) = completion(true)
            override fun error(code: String, message: String?, details: Any?) = completion(false)
            override fun notImplemented() = completion(false)
        })
    }, { value -> emit("downloadOverlayState", value) }, { event, error -> diagnostics.record(event, error) })

    init { channel.setMethodCallHandler(::handle) }
    fun emit(method: String, value: Any? = null) { main.post { channel.invokeMethod(method, value) } }
    fun receiveIntent(intent: Intent?, id: String) {
        if (intent?.action == DownloadOverlay.OPEN_DOWNLOADS) {
            emit("downloadOverlayAction", mapOf("action" to "openDownloads"))
            return
        }
        if (intent == null || (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_VIEW)) return
        val received = Intent(intent)
        externalWorker.execute {
            val request = externalParser.parse(received) ?: return@execute
            if (externalOpens.offer(id, request)) emit("externalOpenAvailable")
        }
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method.startsWith("downloadOverlay")) {
            try {
                when (call.method) {
                    "downloadOverlayShow" -> result.success(downloadOverlay.show(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()))
                    "downloadOverlayUpdate" -> { downloadOverlay.update(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()); result.success(null) }
                    "downloadOverlayClose" -> { downloadOverlay.close(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                diagnostics.record("download.overlay_request_failed", error)
                downloadOverlay.close()
                result.error("overlay", "无法开启悬浮窗，请在系统设置中允许文析助手显示在其他应用上层", null)
            }
            return
        }
        if (call.method == "openExternalPlayer") {
            externalPlayer.open(
                call.argument<String>("url").orEmpty(),
                call.argument<String>("title").orEmpty(),
                call.argument<Number>("positionMs")?.toLong() ?: 0,
                call.argument<String>("session").orEmpty(),
            ) { opened, error ->
                if (error == null) result.success(opened)
                else result.error(error.code, error.message, null)
            }
            return
        }
        if (call.method == "cancelExternalPlayer") {
            externalPlayer.dismiss(session = call.argument<String>("session"))
            result.success(null)
            return
        }
        if (call.method == "takeExternalOpens") {
            result.success(externalOpens.take())
            return
        }
        if (call.method == "downloadsReady") {
            downloadKeepAlive.dartReady()
            result.success(downloadKeepAlive.recoveryExpected)
            return
        }
        if (call.method == "downloadProtectionStatus") {
            result.success(downloadProtection.status())
            return
        }
        if (call.method == "downloadProtectionSettings") {
            try {
                downloadProtection.open(call.argument<String>("kind") ?: "app", activity)
                result.success(null)
            } catch (_: Exception) {
                result.error("settings", "无法打开系统设置，请在应用信息中允许后台运行", null)
            }
            return
        }
        if (call.method == "saveDocument") {
            val current = activity
            val bytes = call.argument<ByteArray>("bytes")
            if (current == null || picker != null || bytes == null || bytes.size > 32 * 1024 * 1024) {
                result.error("document", "无法打开文件保存窗口", null); return
            }
            picker = result
            documentBytes = bytes
            try {
                current.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                    .setType(call.argument<String>("mime") ?: "application/json")
                    .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "文析助手-backup.json"), 833)
            } catch (_: Exception) { picker = null; documentBytes = null; result.error("document", "无法打开文件保存窗口", null) }
            return
        }
        if (call.method == "openFile" || call.method == "shareFile") {
            fileOpening.open(call.argument<String>("path").orEmpty(), call.argument<String>("name").orEmpty(), call.method == "shareFile") { error ->
                if (error == null) result.success(null)
                else result.error(error.code, error.message, null)
            }
            return
        }
        if (call.method == "chooseDirectory") {
            val current = activity
            if (current == null || picker != null) { result.error("busy", "请先关闭当前目录选择窗口", null); return }
            picker = result
            try { current.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), 831) }
            catch (_: Exception) { picker = null; result.error("picker", "无法打开目录选择器", null) }
            return
        }
        if (call.method == "cancelExport") {
            call.argument<String>("id")?.let { exports[it]?.set(true) }
            result.success(null)
            return
        }
        if (call.method == "foreground") {
            try {
                val count = call.argument<Int>("active") ?: 0
                if (count > 0) {
                    NotificationPermission.requestOnce(activity) { event, error -> diagnostics.record(event, error) }
                }
                downloadKeepAlive.update(DownloadNotice.from(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()), result)
            } catch (_: Exception) { result.error("foreground", "无法启动后台下载服务，请回到应用后重试", null) }
            return
        }
        // Register before queueing IO so a pause can cancel a save that has not
        // yet reached its worker thread.
        if (call.method == "saveFile") call.argument<String>("id")?.let { exports[it] = AtomicBoolean(false) }
        val executor = if (call.method == "gopeed") nativeWorker else io
        executor.execute {
            try {
                val value: Any? = when (call.method) {
                    "subtitleFontFiles" -> SubtitleFontFiles.available()
                    "diagnosticPaths" -> mapOf("logs" to File(context.noBackupFilesDir, "diagnostics_flutter").absolutePath, "enabled" to diagnostics.enabled)
                    "diagnosticSnapshot" -> diagnostics.snapshot() + mapOf("downloadProtection" to downloadProtection.status())
                    "diagnosticEnabled" -> { diagnostics.setEnabled(call.argument<Boolean>("enabled") == true); null }
                    "diagnosticClear" -> { diagnostics.clear(); null }
                    "paths" -> {
                        check(cache.mkdirs() || cache.isDirectory)
                        val data = File(context.noBackupFilesDir, "flutter_v1").apply { mkdirs() }
                        mapOf("data" to data.absolutePath, "cache" to cache.absolutePath, "freeBytes" to cache.usableSpace)
                    }
                    "freeSpace" -> storage.freeBytes(call.argument<String>("path") ?: cache.absolutePath)
                    "storagePlan" -> storage.plan(cache, call.argument<String>("destination"))
                    "fileAvailability" -> saver.availability(call.argument<String>("path"))
                    "legacySnapshot" -> LegacyImport(context, vault).read().toString()
                    "gopeed" -> nativeCall(call.argument<String>("method") ?: "", JSONObject(call.argument<String>("args") ?: "{}"))
                    "saveFile" -> {
                        val id = requireNotNull(call.argument<String>("id"))
                        val cancelled = exports[id] ?: AtomicBoolean(false)
                        try {
                            val source = File(requireNotNull(call.argument<String>("source"))).canonicalFile
                            require(source.isFile && source.path.startsWith(cache.canonicalPath + File.separator))
                            val total = source.length()
                            var copied = 0L
                            var reported = -1L
                            var lastReport = 0L
                            saver.save(source, call.argument<String>("name") ?: "download.bin", call.argument<String>("relativePath") ?: "", call.argument<String>("destination")) { count ->
                                if (cancelled.get()) throw IOException("保存已暂停")
                                copied += count
                                val now = SystemClock.elapsedRealtime()
                                if (copied != reported && (copied - reported >= 1024 * 1024 || now - lastReport >= 100 || copied == total)) {
                                    emit("exportProgress", mapOf("id" to id, "token" to call.argument<Number>("token"), "copied" to copied, "total" to total))
                                    reported = copied
                                    lastReport = now
                                }
                            }
                        } finally { exports.remove(id, cancelled) }
                    }
                    "deleteFile" -> { saver.deleteOrThrow(call.argument<String>("path")); null }
                    else -> throw IllegalArgumentException("未知平台请求")
                }
                main.post { result.success(value) }
            } catch (error: LinkageError) {
                diagnostics.record("bridge.${call.method}", error)
                main.post { result.error("native", "下载组件加载失败，请安装适配当前设备的完整安装包", null) }
            } catch (error: SecurityException) {
                diagnostics.record("bridge.${call.method}", error)
                main.post { result.error("permission", "目录权限已失效，请重新选择下载目录后重试", null) }
            } catch (error: Throwable) {
                if (!call.method.startsWith("diagnostic")) diagnostics.record("bridge.${call.method}", error)
                val message = when (call.method) {
                    "legacySnapshot" -> "旧版数据读取失败，原文件已保留，可稍后重试导入"
                    "deleteFile" -> "文件未能删除，请检查目录权限后重试"
                    "saveFile" -> if (error.message == "保存已暂停") "保存已暂停" else "无法保存下载文件，请检查存储空间和目录权限"
                    else -> "下载组件操作失败，请重试并检查下载目录"
                }
                main.post { result.error("operation", message, null) }
            }
        }
    }
    fun activityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (fileOpening.activityResult(requestCode)) return true
        if (requestCode == 833) {
            val result = picker ?: return true
            val bytes = documentBytes
            picker = null; documentBytes = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null || bytes == null) { result.success(null); return true }
            io.execute {
                try {
                    context.contentResolver.openOutputStream(uri, "w")?.use { it.write(bytes); it.flush() } ?: error("Cannot write")
                    main.post { result.success(uri.toString()) }
                } catch (_: Exception) { main.post { result.error("document", "文件导出失败，请检查目录权限", null) } }
            }
            return true
        }
        if (requestCode != 831) return false
        val result = picker ?: return true
        picker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return true }
        try {
            context.contentResolver.takePersistableUriPermission(uri, (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            result.success(uri.toString())
        } catch (_: Exception) { result.error("permission", "无法保存此目录的访问权限", null) }
        return true
    }
    private fun nativeCall(method: String, args: JSONObject): String {
        val id = args.optString("id")
        if (method in setOf("pause", "remove", "snapshot")) require(id.matches(Regex("[A-Za-z0-9_-]{1,100}")))
        when (method) {
            "version" -> return "{\"version\":\"1.8.1\",\"protocol\":1}"
            "open" -> openNative()
            "begin" -> { check(nativeStarted); Gopeed.begin(args.toString()) }
            "httpProbeStart" -> { check(nativeStarted); Gopeed.startHttpProbe(args.toString()) }
            "httpProbeStatus" -> { check(nativeStarted); return Gopeed.httpProbeStatus(id) }
            "httpProbeStop" -> if (nativeStarted) Gopeed.stopHttpProbe(id)
            "torrentResolve" -> { check(nativeStarted); Gopeed.resolveTorrent(args.toString()) }
            "torrentMetadata" -> { check(nativeStarted); return Gopeed.torrentMetadata(id) }
            "torrentCancel" -> if (nativeStarted) Gopeed.cancelTorrent(id)
            "torrentStreamStart" -> { check(nativeStarted); return Gopeed.startTorrentStream(args.toString()) }
            "torrentStreamStatus" -> { check(nativeStarted); return Gopeed.torrentStreamStatus(id) }
            "torrentStreamStop" -> if (nativeStarted) Gopeed.stopTorrentStream(id)
            "torrentStreamInterrupt" -> if (nativeStarted) Gopeed.interruptTorrentStream(id)
            "snapshot" -> { check(nativeStarted); return Gopeed.snapshot(id) }
            "pause" -> if (nativeStarted) Gopeed.pause(id)
            "remove" -> if (nativeStarted) Gopeed.remove(id)
            "close" -> if (nativeStarted) { Gopeed.close(); nativeStarted = false }
            else -> error("Unknown native method")
        }
        return "null"
    }
    private fun openNative() {
        val directory = File(context.noBackupFilesDir, "gopeed")
        check(directory.mkdirs() || directory.isDirectory)
        check(cache.mkdirs() || cache.isDirectory)
        if (!nativeStarted) {
        val keyFile = AtomicFile(File(directory, "engine.key"))
        val key = if (keyFile.baseFile.exists()) {
            vault.open(keyFile.readFully().toString(Charsets.UTF_8)) ?: error("Native state key unavailable")
        } else {
            check(!File(directory, "gopeed.db").exists())
            val bytes = ByteArray(32).also(SecureRandom()::nextBytes)
            val value = Base64.encodeToString(bytes, Base64.NO_WRAP)
            bytes.fill(0)
            val stream = keyFile.startWrite()
            try { stream.write(vault.seal(value).toByteArray(Charsets.UTF_8)); keyFile.finishWrite(stream) }
            catch (error: Throwable) { keyFile.failWrite(stream); throw error }
            value
        }
        Seq.setContext(context.applicationContext)
        Gopeed.open(directory.absolutePath, cache.absolutePath, key)
        nativeStarted = true
        }
        File(directory, "pending-removals").listFiles()?.forEach { marker ->
            require(marker.name.matches(Regex("[A-Za-z0-9_-]{1,100}")))
            Gopeed.remove(marker.name)
            check(marker.delete() || !marker.exists())
        }
    }
}
