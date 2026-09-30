package com.meowwoof.translator.pose

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * 宠物前置检测（需求 3，常驻运行）。
 *
 * 用一个小体积 SSD（MobileNet-SSD INT8，约 4MB）判断画面里是否有猫/狗：
 *  - 检测到猫狗 → 才进入 HRNet 姿态推理（省电、避免对空场景误判）；
 *  - 没检测到 → 跳过姿态推理（hasPet=false，UI 提示"未检测到宠物"）。
 *
 * ★ 模型约定（需与最终导出的 SSD TFLite 对齐，可改常量）：
 *   - 输入：float32 [1,3,300,300]（NCHW），中心方裁剪 → ImageNet 归一化。
 *   - 输出：TensorFlow Detection_PostProcess 标准 4 张量：
 *        locations  [1, N, 4]   (y,x,h,w 归一化)
 *        classes    [1, N]      (类别 id，含背景 0)
 *        scores     [1, N]      (置信 0-1)
 *        numDet     [1]         (整数检测数)
 *     COCO 类别：cat=16, dog=17（0=背景）。如模型类别不同，改 CAT_ID/DOG_ID。
 *
 * ⚠️ 该 4MB 模型不打包进 APK（避免体积膨胀），运行时从 assets 拷到 cache 目录加载；
 *   若 assets 内缺该模型，则降级为"始终认为有宠物"（detect 返回 true），
 *   不阻断体态识别主流程（只是少了空场景过滤）。
 */
class SsdDetector private constructor(
    private val interpreter: org.tensorflow.lite.Interpreter
) {
    companion object {
        private const val TAG = "SsdDetect"
        private const val MODEL_FILE_NAME = "pet_ssd_mobilenet_int8.tflite"
        private const val IN_W = 300
        private const val IN_H = 300
        private const val CONF_THRESHOLD = 0.5f
        // COCO 80 类里猫/狗的 id（含背景 0 起算）
        private const val CAT_ID = 16f
        private const val DOG_ID = 17f

        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)

        fun load(modelPath: String): SsdDetector {
            val opt = org.tensorflow.lite.Interpreter.Options().setNumThreads(2)
            val f = File(modelPath)
            val buffer = FileInputStream(f).channel.use { ch ->
                ch.map(FileChannel.MapMode.READ_ONLY, 0, f.length())
            }
            val itp = org.tensorflow.lite.Interpreter(buffer, opt)
            Log.i(TAG, "SSD loaded: $modelPath, outputs=${itp.outputTensorCount}")
            return SsdDetector(itp)
        }

        /**
         * 从 assets 拷到 cache 并加载；assets 缺模型时返回 null（调用方降级为"有宠物"）。
         */
        fun loadFromAssets(ctx: Context): SsdDetector? {
            return try {
                val target = File(ctx.cacheDir, MODEL_FILE_NAME)
                if (!target.exists() || target.length() == 0L) {
                    ctx.assets.open(MODEL_FILE_NAME).use { ins ->
                        FileOutputStream(target).use { ins.copyTo(it) }
                    }
                }
                if (target.length() < 100_000L) { // 远小于 4MB，视为缺失
                    target.delete(); return null
                }
                load(target.absolutePath)
            } catch (t: Throwable) {
                Log.w(TAG, "SSD model not available (degrade to always-pet): ${t.message}")
                null
            }
        }
    }

    /**
     * 判断画面是否有猫/狗。
     * @return true=有宠物（或模型缺失降级）；false=明确无宠物。
     */
    fun detect(bitmap: Bitmap): Boolean {
        return try {
            val input = preprocess(bitmap)
            val outputs = HashMap<Int, Any>()
            // 标准检测输出 4 张量：locations/classes/scores/numDet
            val loc = Array(1) { Array(10) { FloatArray(4) } }
            val cls = Array(1) { FloatArray(10) }
            val scr = Array(1) { FloatArray(10) }
            val num = FloatArray(1)
            outputs[0] = loc
            outputs[1] = cls
            outputs[2] = scr
            outputs[3] = num
            interpreter.runForMultipleInputsOutputs(arrayOf(input), outputs)
            val n = num[0].toInt().coerceAtMost(10)
            for (i in 0 until n) {
                val s = scr[0][i]
                val c = cls[0][i]
                if (s >= CONF_THRESHOLD && (c == CAT_ID || c == DOG_ID)) {
                    Log.d(TAG, "pet detected: class=$c score=${"%.2f".format(s)}")
                    return true
                }
            }
            Log.d(TAG, "no pet above threshold (n=$n)")
            false
        } catch (t: Throwable) {
            Log.e(TAG, "SSD detect failed (treat as pet): ${t.message}")
            true // 异常时降级为"有宠物"，不阻断
        }
    }

    private fun preprocess(src: Bitmap): ByteBuffer {
        val side = minOf(src.width, src.height)
        val dx = (src.width - side) / 2
        val dy = (src.height - side) / 2
        val square = Bitmap.createBitmap(src, dx, dy, side, side)
        val scaled = Bitmap.createScaledBitmap(square, IN_W, IN_H, true)
        val px = IntArray(IN_W * IN_H)
        scaled.getPixels(px, 0, IN_W, 0, 0, IN_W, IN_H)
        val plane = IN_W * IN_H
        val buf = ByteBuffer.allocateDirect(plane * 3 * 4).order(ByteOrder.nativeOrder())
        val r = FloatArray(plane); val g = FloatArray(plane); val b = FloatArray(plane)
        for (i in px.indices) {
            val v = px[i]
            r[i] = ((v shr 16 and 0xFF) / 255f - MEAN[0]) / STD[0]
            g[i] = ((v shr 8 and 0xFF) / 255f - MEAN[1]) / STD[1]
            b[i] = ((v and 0xFF) / 255f - MEAN[2]) / STD[2]
        }
        for (i in 0 until plane) buf.putFloat(r[i])
        for (i in 0 until plane) buf.putFloat(g[i])
        for (i in 0 until plane) buf.putFloat(b[i])
        buf.rewind()
        return buf
    }

    fun close() {
        try { interpreter.close() } catch (_: Exception) {}
    }
}
