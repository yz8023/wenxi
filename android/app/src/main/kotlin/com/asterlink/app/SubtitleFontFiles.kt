package com.asterlink.app

import android.graphics.fonts.SystemFonts
import android.os.Build
import java.io.File

internal object SubtitleFontFiles {
    // Called on NativeBridge's IO worker, including API 24-28 where the public
    // SystemFonts API is unavailable. No font data crosses the platform channel.
    fun available(): List<String> {
        val paths = linkedSetOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                SystemFonts.getAvailableFonts().forEach { font ->
                    font.file?.let { paths.add(it.absolutePath) }
                }
            }
        }
        for (root in listOf("/system/fonts", "/product/fonts", "/system_ext/fonts", "/vendor/fonts")) {
            runCatching {
                File(root).listFiles()?.forEach { file ->
                    if (file.isFile && file.extension.lowercase() in setOf("otf", "ttf", "ttc")) {
                        paths.add(file.absolutePath)
                    }
                }
            }
        }
        return paths.toList()
    }
}
