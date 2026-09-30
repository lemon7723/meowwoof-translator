package com.meowwoof.translator.pose

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * 体态模型下载管理器（独立于语音/播放模块，任何异常只影响体态功能）。
 *
 * v1.6.0：模型换用 SuperAnimal HRNet-w32（INT8 量化，24 关键点，54.6MB，Apache-2.0）。
 * 模型不打包进 APK；首次进入 Pet Mood Capture 才远端下载并本地 cache 持久缓存。
 *
 * 下载策略（需求 2）：
 *  - MODEL_URL 主地址 + FALLBACK_URLS 备用链
 *  - 每条 URL 最多 3 次重试，间隔 2 秒
 *  - 百分比进度 UI 展示（回调 0-100）
 *  - 断点续传（Range 头 + .part 临时文件）
 *  - 完成后 SHA-256 哈希校验（EXPECTED_SHA256 留空时跳过，托管后填入即生效）
 *  - 再加 TFLite 试加载校验（损坏文件当场删除）
 *
 * ⚠️ 你需把 HRNet-w32 INT8 的 TFLite 文件托管到可直链下载的地址，并把真实
 *    SHA-256 填入 EXPECTED_SHA256（留空则仅做大小 + 试加载校验）。
 */
object ModelDownloadManager {

    private const val TAG = "PoseDownload"

    /** 模型文件名（cache 内，后续离线复用） */
    const val MODEL_FILE_NAME = "superanimal_hrnet_w32_int8.tflite"

    /** 模型下载主地址（HRNet-w32 INT8，54.6MB）。替换为你的托管直链。 */
    const val MODEL_URL =
        "https://github.com/your-org/meowwoof-models/raw/main/superanimal_hrnet_w32_int8.tflite"

    /** 备用直链，主地址失效时依次尝试 */
    val FALLBACK_URLS = listOf(
        "https://raw.githubusercontent.com/your-org/meowwoof-models/main/superanimal_hrnet_w32_int8.tflite"
    )

    /**
     * 期望的 SHA-256（hex，小写）。填入后做强校验；留空仅做大小 + 试加载校验。
     * 计算方式（本地）：sha256sum superanimal_hrnet_w32_int8.tflite
     */
    const val EXPECTED_SHA256 = ""

    private const val MAX_RETRIES = 3
    private const val RETRY_DELAY_MS = 2000L
    private const val CONNECT_TIMEOUT_MS = 15000
    private const val READ_TIMEOUT_MS = 30000

    /** 完整性下限（HRNet-w32 INT8 ≈ 54.6MB，低于视为损坏） */
    private const val MIN_VALID_BYTES = 40_000_000L

    fun interface ProgressListener {
        fun onProgress(percent: Int)
    }

    fun modelFile(ctx: Context): File =
        File(ctx.cacheDir, MODEL_FILE_NAME)

    fun hasValidCachedModel(ctx: Context): Boolean {
        val f = modelFile(ctx)
        if (!f.exists() || f.length() < MIN_VALID_BYTES) return false
        if (EXPECTED_SHA256.isNotEmpty() && !verifySha256(f, EXPECTED_SHA256)) {
            Log.w(TAG, "cached model sha256 mismatch, delete")
            f.delete(); return false
        }
        return try {
            PoseEstimator.validateModel(f.absolutePath)
        } catch (t: Throwable) {
            Log.w(TAG, "cached model invalid: ${t.message}")
            false
        }
    }

    @Synchronized
    fun ensureModel(ctx: Context, listener: ProgressListener): File {
        if (hasValidCachedModel(ctx)) {
            Log.i(TAG, "model cached, reuse: ${modelFile(ctx).absolutePath}")
            listener.onProgress(100)
            return modelFile(ctx)
        }
        val urls = listOf(MODEL_URL) + FALLBACK_URLS
        var lastErr: Throwable? = null
        for (url in urls) {
            for (attempt in 1..MAX_RETRIES) {
                try {
                    Log.i(TAG, "download attempt $attempt/$MAX_RETRIES: $url")
                    val f = downloadWithResume(ctx, url, listener)
                    if (f.length() < MIN_VALID_BYTES) {
                        throw IOException("file too small: ${f.length()} bytes")
                    }
                    if (EXPECTED_SHA256.isNotEmpty() && !verifySha256(f, EXPECTED_SHA256)) {
                        throw IOException("sha256 mismatch")
                    }
                    PoseEstimator.validateModel(f.absolutePath)
                    Log.i(TAG, "download OK: ${f.length()} bytes -> ${f.absolutePath}")
                    return f
                } catch (t: Throwable) {
                    lastErr = t
                    Log.w(TAG, "attempt $attempt failed: ${t.javaClass.simpleName}: ${t.message}")
                    try { modelFile(ctx).delete() } catch (_: Exception) {}
                    if (attempt < MAX_RETRIES) {
                        try { Thread.sleep(RETRY_DELAY_MS) } catch (_: InterruptedException) {}
                    }
                }
            }
        }
        throw PoseDownloadException("all URLs failed after $MAX_RETRIES retries", lastErr)
    }

    private fun downloadWithResume(
        ctx: Context, urlStr: String, listener: ProgressListener
    ): File {
        val finalFile = modelFile(ctx)
        val partFile = File(ctx.cacheDir, "$MODEL_FILE_NAME.part")
        var downloaded = if (partFile.exists()) partFile.length() else 0L

        val conn = URL(urlStr).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.instanceFollowRedirects = true
            if (downloaded > 0) {
                conn.setRequestProperty("Range", "bytes=$downloaded-")
                Log.d(TAG, "resume from $downloaded bytes")
            }
            val code = conn.responseCode
            val resuming = (code == 206)
            if (code != 200 && code != 206) {
                throw IOException("HTTP $code for $urlStr")
            }
            if (!resuming && downloaded > 0) {
                Log.d(TAG, "server ignored Range, restart from 0")
                downloaded = 0
                partFile.delete()
            }
            val total = conn.contentLengthLong.let { if (it > 0) it + downloaded else -1L }
            Log.d(TAG, "response $code, total=${if (total > 0) total else "unknown"}")

            conn.inputStream.use { input ->
                java.io.FileOutputStream(partFile, true).use { out ->
                    val buf = ByteArray(64 * 1024)
                    var lastPct = -1
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        downloaded += n
                        if (total > 0) {
                            val pct = ((downloaded * 100) / total).toInt().coerceIn(0, 100)
                            if (pct != lastPct) {
                                lastPct = pct
                                try { listener.onProgress(pct) } catch (_: Exception) {}
                            }
                        }
                    }
                }
            }
            if (finalFile.exists()) finalFile.delete()
            if (!partFile.renameTo(finalFile)) {
                partFile.copyTo(finalFile, overwrite = true)
                partFile.delete()
            }
            return finalFile
        } finally {
            try { conn.disconnect() } catch (_: Exception) {}
        }
    }

    /** SHA-256 校验（与 EXPECTED_SHA256 比对） */
    private fun verifySha256(file: File, expected: String): Boolean {
        return try {
            val md = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { fis ->
                val buf = ByteArray(256 * 1024)
                var n: Int
                while (fis.read(buf).also { n = it } > 0) md.update(buf, 0, n)
            }
            val hex = md.digest().joinToString("") { "%02x".format(it) }
            val ok = hex.equals(expected, ignoreCase = true)
            if (!ok) Log.w(TAG, "sha256 mismatch: got $hex expected $expected")
            ok
        } catch (t: Throwable) {
            Log.e(TAG, "sha256 calc failed: ${t.message}")
            false
        }
    }
}

class PoseDownloadException(message: String, cause: Throwable? = null)
    : Exception(message, cause)
