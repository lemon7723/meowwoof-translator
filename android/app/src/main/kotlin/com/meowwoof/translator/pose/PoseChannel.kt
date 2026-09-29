package com.meowwoof.translator.pose

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

/**
 * 体态识别 MethodChannel（channel: "meowwoof/pose"）。
 *
 * 方法：
 *   prepareModel           → 确保模型就绪（下载/复用），回调 progress 0-100
 *   inferFromPath(path, species) → {audio 无关} 体态推理 → {poseEmotion, detail, conf}
 *   merge(audioEmotion, poseEmotion) → {conclusion, isSingleSource, ...}
 *
 * 硬性要求（需求 6）：本 channel 内任何异常都以 result.error 返回，
 * 绝不向 Flutter 外抛出，绝不影响录音/播放器/预设叫声。
 */
object PoseChannel {

    private const val TAG = "PoseChannel"
    const val CHANNEL = "meowwoof/pose"

    private val executor = Executors.newSingleThreadExecutor()

    @Volatile private var estimator: PoseEstimator? = null

    fun register(activity: Activity, messenger: io.flutter.plugin.common.BinaryMessenger) {
        io.flutter.plugin.common.MethodChannel(messenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepareModel" -> {
                        val ctx = activity.applicationContext
                        val channel = io.flutter.plugin.common.MethodChannel(messenger, CHANNEL)
                        executor.execute {
                            try {
                                val f = ModelDownloadManager.ensureModel(ctx) { pct ->
                                    // 进度推送：MethodChannel 调用必须在主线程（@UiThread），
                                    // 此处在下载线程，必须经 main{} 切换，否则抛
                                    // "Methods marked with @UiThread must be executed on the main thread"
                                    // 并中断整个下载（v1.5.7 模拟器实测踩坑）
                                    main { channel.invokeMethod("onProgress", pct) }
                                }
                                main { result.success(mapOf("path" to f.absolutePath)) }
                            } catch (t: Throwable) {
                                Log.e(TAG, "prepareModel failed: ${t.message}")
                                main { result.error("DOWNLOAD_FAIL", t.message, null) }
                            }
                        }
                    }
                    "inferFromPath" -> {
                        val path = call.argument<String>("path") ?: ""
                        val species = call.argument<String>("species") ?: "cat"
                        executor.execute {
                            try {
                                val est = obtainEstimator(activity)
                                val bmp = decodeBitmap(activity, path)
                                    ?: throw IllegalStateException("图片解析失败")
                                val r = est.detect(bmp)
                                if (r == null) {
                                    main { result.success(mapOf<String, Any?>("found" to false)) }
                                    return@execute
                                }
                                val emo = PoseRules.judge(species, r.kpts)
                                if (emo == null) {
                                    main { result.success(mapOf<String, Any?>("found" to false)) }
                                    return@execute
                                }
                                main {
                                    result.success(mapOf(
                                        "found" to true,
                                        "conf" to r.conf,
                                        "poseEmotion" to emo.label,
                                        "detail" to emo.detail,
                                    ))
                                }
                            } catch (t: Throwable) {
                                Log.e(TAG, "infer failed: ${t.message}")
                                main { result.error("INFER_FAIL", t.message, null) }
                            }
                        }
                    }
                    "merge" -> {
                        try {
                            val a = call.argument<String>("audio")
                            val p = call.argument<String>("pose")
                            val fr = EmotionFusion.mergePetEmotion(a, p)
                            result.success(mapOf(
                                "audioEmotion" to fr.audioEmotion,
                                "poseEmotion" to fr.poseEmotion,
                                "conclusion" to fr.conclusion,
                                "isSingleSource" to fr.isSingleSource,
                            ))
                        } catch (t: Throwable) {
                            Log.e(TAG, "merge failed: ${t.message}")
                            result.error("FUSION_FAIL", t.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        Log.i(TAG, "pose channel registered")
    }

    /** 懒加载推理器；模型文件缺失时抛异常由调用方 catch */
    private fun obtainEstimator(activity: Activity): PoseEstimator {
        estimator?.let { return it }
        val f = ModelDownloadManager.modelFile(activity)
        if (!f.exists()) throw IllegalStateException("模型未就绪")
        val e = PoseEstimator.load(f.absolutePath)
        estimator = e
        return e
    }

    /** 从 content:// 或文件路径解码降采样 Bitmap（限制最大边 1024，防 OOM） */
    private fun decodeBitmap(activity: Activity, path: String): Bitmap? {
        return try {
            val uri = if (path.startsWith("content:")) Uri.parse(path) else null
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            if (uri != null) {
                activity.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, bounds)
                }
            } else {
                BitmapFactory.decodeFile(path, bounds)
            }
            var sample = 1
            val maxSide = maxOf(bounds.outWidth, bounds.outHeight)
            while (maxSide / (sample * 2) >= 1024) sample *= 2
            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            if (uri != null) {
                activity.contentResolver.openInputStream(uri)?.use {
                    BitmapFactory.decodeStream(it, null, opts)
                }
            } else {
                BitmapFactory.decodeFile(path, opts)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "decodeBitmap failed: ${t.message}")
            null
        }
    }

    private fun main(block: () -> Unit) {
        android.os.Handler(android.os.Looper.getMainLooper()).post(block)
    }
}
