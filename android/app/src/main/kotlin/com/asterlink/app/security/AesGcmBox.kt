package com.asterlink.app.security

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-GCM 加解密盒。与密钥来源解耦：调用方提供 [SecretKey]，
 * 因此单测可以用内存密钥覆盖加解密往返、IV 随机性和篡改检测，
 * 而不依赖 AndroidKeyStore（JVM 单元测试里没有这个 Provider）。
 *
 * 输出格式：12 字节随机 IV + 密文 + 16 字节 GCM tag，原始字节数组。
 * 上层负责 Base64 编码。
 */
internal object AesGcmBox {
    const val IV_LENGTH = 12
    const val TAG_BITS = 128
    private const val TRANSFORMATION = "AES/GCM/NoPadding"

    fun seal(key: SecretKey, plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        require(iv.size == IV_LENGTH) { "GCM IV 长度异常：${iv.size}" }
        val ciphertext = cipher.doFinal(plaintext)
        return iv + ciphertext
    }

    fun open(key: SecretKey, packed: ByteArray): ByteArray {
        require(packed.size > IV_LENGTH) { "密文过短，不是有效的 AES-GCM 数据" }
        val iv = packed.copyOfRange(0, IV_LENGTH)
        val ciphertext = packed.copyOfRange(IV_LENGTH, packed.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    fun randomIv(): ByteArray = ByteArray(IV_LENGTH).also(SecureRandom()::nextBytes)
}
