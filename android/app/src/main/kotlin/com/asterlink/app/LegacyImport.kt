package com.asterlink.app

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.datastore.preferences.preferencesDataStore
import com.asterlink.app.security.SecureVault
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

private val Context.legacyPreferences by preferencesDataStore("asterlink_settings_v1")

/** Read-only bridge for the previous package's own data, never another app's data. */
class LegacyImport(private val context: Context, private val vault: SecureVault) {
    fun read(): JSONObject {
        val credentials = JSONObject()
        val secrets = JSONObject()
        val oldPreferences = context.getSharedPreferences("asterlink_secure_v1", Context.MODE_PRIVATE)
        for (key in oldPreferences.all.keys) {
            if (key.startsWith("credential.")) {
                val platform = key.removePrefix("credential.")
                val value = vault.getCredential(platform) ?: error("Legacy credential cannot be decrypted")
                credentials.put(platform, JSONObject().put("label", value.label).put("updatedAt", value.updatedAt).put("fields", JSONObject(value.fields)))
            } else if (key.startsWith("secret.")) {
                val name = key.removePrefix("secret.")
                secrets.put(name, vault.getSecret(name) ?: error("Legacy secret cannot be decrypted"))
            }
        }
        val result = JSONObject().put("credentials", credentials).put("secrets", secrets)
        val databaseFile = context.getDatabasePath("asterlink_v1.db")
        if (databaseFile.isFile) {
            SQLiteDatabase.openDatabase(databaseFile.absolutePath, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                result.put("history", table(db, "parse_history"))
                val tasks = table(db, "download_tasks")
                for (i in 0 until tasks.length()) {
                    val task = tasks.getJSONObject(i)
                    val url = task.optString("url")
                    task.put("url", vault.open(url) ?: url.takeIf { it.startsWith("https://") || it.startsWith("http://") } ?: "")
                    val headers = task.optString("encryptedHeaders")
                    task.put("headers", if (headers.isBlank()) JSONObject() else JSONObject(vault.open(headers) ?: error("Legacy headers cannot be decrypted")))
                    if (!task.isNull("encryptedSource")) {
                        task.put("source", JSONObject(vault.open(task.getString("encryptedSource")) ?: error("Legacy source cannot be decrypted")))
                    }
                    task.remove("encryptedHeaders")
                    task.remove("encryptedSource")
                }
                result.put("tasks", tasks)
                val cleanups = table(db, "download_cleanups")
                for (i in 0 until cleanups.length()) {
                    val item = cleanups.getJSONObject(i)
                    item.put("payload", JSONObject(vault.open(item.getString("encryptedPayload")) ?: error("Legacy cleanup cannot be decrypted")))
                    item.remove("encryptedPayload")
                }
                result.put("cleanups", cleanups)
            }
        }
        if (File(context.filesDir, "datastore/asterlink_settings_v1.preferences_pb").isFile) {
            val values = runBlocking(Dispatchers.IO) { context.legacyPreferences.data.first() }.asMap().entries.associate { it.key.name to it.value }
            val overrides = (values["gopeed_thread_overrides"] as? String)?.let { JSONObject(it) } ?: JSONObject()
            result.put("settings", JSONObject().put("theme", values["theme"] ?: "System")
                .put("threads", values["gopeed_thread_count"] ?: 64).put("concurrent", values["gopeed_concurrent_tasks"] ?: 3)
                .put("retries", values["retry_count"] ?: 3).put("speedLimit", values["speed_limit"] ?: 0)
                .put("downloadThreadOverrides", overrides).put("destination", values["destination_tree"] ?: JSONObject.NULL))
        }
        return result
    }
    private fun table(db: SQLiteDatabase, name: String): JSONArray {
        require(name in setOf("parse_history", "download_tasks", "download_cleanups"))
        val exists = db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name=?", arrayOf(name)).use { it.moveToFirst() }
        if (!exists) return JSONArray()
        return db.rawQuery("SELECT * FROM $name", null).use { cursor ->
            JSONArray().apply {
                while (cursor.moveToNext()) {
                    put(JSONObject().apply {
                        for (i in 0 until cursor.columnCount) {
                            put(cursor.getColumnName(i), when (cursor.getType(i)) {
                                Cursor.FIELD_TYPE_NULL -> JSONObject.NULL
                                Cursor.FIELD_TYPE_INTEGER -> cursor.getLong(i)
                                Cursor.FIELD_TYPE_FLOAT -> cursor.getDouble(i)
                                else -> cursor.getString(i)
                            })
                        }
                    })
                }
            }
        }
    }
}
