package com.meowwoof.translator.pose

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * 体态模型下载管理器（独立于语音/播放模块，任何异常只影响体态功能）。
 *
 * 职责：
 *  1. 检查私有 cache 是否已有模型 → 离线复用
 *  2. 依次尝试 MODEL_URL / FALLBACK_URLS，下载到 cacheDir
 *  3. 下载进度回调（0-100），UI 展示百分比
 *  4. 重试：每条 URL 最多 3 次，间隔 2 秒
 *  5. 断点续传：Range 头 + .part 临时文件
 *  6. 完成后校验文件大小下限，防止损坏/半截文件；再加 TFLite 试加载校验
 *
 * 日志 TAG：PoseDownload（关键步骤全打点，方便调试）
 */
object ModelDownloadManager {

    private const val TAG = "PoseDownload"

    /** 模型文件在 cache 内的文件名（后续离线复用） */
    const val MODEL_FILE_NAME = "yolov8n-pose_int8.tflite"

    /** 模型下载直链（GitHub Raw），后续更换只改这里 */
    const val MODEL_URL =
        "https://raw.githubusercontent.com/ultralytics/assets/main/models/yolov8n-pose_int8.tflite"

    /**
     * 备用直链：主 URL 失效时依次尝试。
     * 注：ultralytics 官方 assets 仓库从未发布过 pose tflite（实测 404），
     * 下面的备用链是本项目仓库的 raw 直链：
     * yolov8n-pose fp16 tflite（256px 输入，官方权重导出，实测 200/6.67MB）。
     */
    val FALLBACK_URLS = listOf(
        "https://raw.githubusercontent.com/lemon7723/meowwoof-translator/main/models/yolov8n-pose_fp16.tflite"
    )

    /** 重试参数 */
    private const val MAX_RETRIES = 3
    private const val RETRY_DELAY_MS = 2000L
    private const val CONNECT_TIMEOUT_MS = 15000
    private const val READ_TIMEOUT_MS = 30000

    /** 完整性校验：小于该字节数视为损坏（yolov8n-pose int8 实际约 3-6MB） */
    private const val MIN_VALID_BYTES = 1_000_000L

    /** 下载进度回调：0-100 */
    fun interface ProgressListener {
        fun onProgress(percent: Int)
    }

    fun modelFile(ctx: Context): File =
        File(ctx.cacheDir, MODEL_FILE_NAME)

    /** 缓存内是否已有通过校验的模型 */
    fun hasValidCachedModel(ctx: Context): Boolean {
        val f = modelFile(ctx)
        if (!f.exists() || f.length() < MIN_VALID_BYTES) return false
        return try {
            PoseEstimator.validateModel(f.absolutePath)
        } catch (t: Throwable) {
            Log.w(TAG, "cached model invalid: ${t.message}")
            false
        }
    }

    /**
     * 确保模型就绪：有缓存直接返回；否则下载。
     * @throws PoseDownloadException 全部 URL 重试后仍失败时抛出（调用方 catch 后禁用体态功能）
     */
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
                    // 试加载校验：损坏文件当场删除，进入下一次重试
                    PoseEstimator.validateModel(f.absolutePath)
                    Log.i(TAG, "download OK: ${f.length()} bytes -> ${f.absolutePath}")
                    return f
                } catch (t: Throwable) {
                    lastErr = t
                    Log.w(TAG, "attempt $attempt failed: ${t.javaClass.simpleName}: ${t.message}")
                    // 删除半截文件，保留续传基线（.part 不删）
                    try { modelFile(ctx).delete() } catch (_: Exception) {}
                    if (attempt < MAX_RETRIES) {
                        try { Thread.sleep(RETRY_DELAY_MS) } catch (_: InterruptedException) {}
                    }
                }
            }
        }
        throw PoseDownloadException("all URLs failed after $MAX_RETRIES retries", lastErr)
    }

    /** 断点续传下载：先探测已有 .part 长度，带 Range 头请求 */
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
            // 服务器不支持 Range 时从头下
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
            // 下载完成：.part → 正式文件
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
}

/** 下载失败（网络不通/全部重试失败） */
class PoseDownloadException(message: String, cause: Throwable? = null)
    : Exception(message, cause)
