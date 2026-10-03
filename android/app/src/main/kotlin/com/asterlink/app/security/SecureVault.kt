package com.asterlink.app.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

data class StoredCredential(
    val label: String,
    val fields: Map<String, String>,
    val updatedAt: Long = System.currentTimeMillis()
)

/**
 * 凭据读写接口。把 [SecureVault] 的 Android 依赖（Keystore、SharedPreferences）
 * 与使用方隔离，使备份等纯逻辑可以在 JVM 单测里用内存实现替换。
 */
interface CredentialStore {
    fun putCredential(platformKey: String, credential: StoredCredential)
    fun getCredential(platformKey: String): StoredCredential?
    fun removeCredential(platformKey: String)
    fun putSecret(key: String, value: String)
    fun getSecret(key: String): String?
    fun removeSecret(key: String)

    /** 后台令牌刷新只能更新原账号，不能覆盖换号或退出登录产生的新状态。 */
    fun replaceCredential(platformKey: String, expected: StoredCredential?, replacement: StoredCredential): Boolean = synchronized(this) {
        if (getCredential(platformKey) != expected) false else {
            putCredential(platformKey, replacement)
            true
        }
    }
}

class SecureVault(context: Context) : CredentialStore {
    private val preferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    @Synchronized
    override fun putCredential(platformKey: String, credential: StoredCredential) {
        val json = JSONObject().apply {
            put("label", credential.label)
            put("updatedAt", credential.updatedAt)
            put("fields", JSONObject(credential.fields))
        }.toString()
        preferences.edit().putString("credential.$platformKey", encrypt(json)).apply()
    }

    @Synchronized
    override fun getCredential(platformKey: String): StoredCredential? {
        val encrypted = preferences.getString("credential.$platformKey", null) ?: return null
        return runCatching {
            val json = JSONObject(decrypt(encrypted))
            val fieldsJson = json.getJSONObject("fields")
            val fields = fieldsJson.keys().asSequence().associateWith(fieldsJson::getString)
            StoredCredential(
                label = json.optString("label"),
                fields = fields,
                updatedAt = json.optLong("updatedAt")
            )
        }.getOrNull()
    }

    @Synchronized
    override fun removeCredential(platformKey: String) {
        preferences.edit().remove("credential.$platformKey").apply()
    }

    @Synchronized
    override fun putSecret(key: String, value: String) {
        preferences.edit().putString("secret.$key", encrypt(value)).apply()
    }

    @Synchronized
    override fun getSecret(key: String): String? = preferences.getString("secret.$key", null)?.let { encrypted ->
        runCatching { decrypt(encrypted) }.getOrNull()
    }

    @Synchronized
    override fun removeSecret(key: String) {
        preferences.edit().remove("secret.$key").apply()
    }

    fun seal(value: String): String = encrypt(value)

    fun open(value: String): String? = runCatching { decrypt(value) }.getOrNull()

    private fun encrypt(value: String): String {
        val packed = AesGcmBox.seal(secretKey(), value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        val packed = Base64.decode(value, Base64.NO_WRAP)
        return AesGcmBox.open(secretKey(), packed).toString(Charsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setRandomizedEncryptionRequired(true)
                    .build()
            )
            generateKey()
        }
    }

    private companion object {
        const val PREFS_NAME = "asterlink_secure_v1"
        const val KEY_ALIAS = "com.asterlink.app.secure.v1"
    }
}
