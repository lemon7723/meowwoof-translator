package com.meowwoof.translator.pose

import android.graphics.Bitmap
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * SuperAnimal HRNet-w32（INT8 量化）TFLite 推理器（v1.6.0）。
 *
 * 替换原 RTMPose-Animal（AP-10K 17 点 SimCC）。HRNet 输出关键点热力图，
 * 解析方式由 SimCC → 高斯热力图 argmax（含 1/4 像素精修）。
 *
 * ★ 关键假设（需与最终导出的 HRNet-w32 TFLite 模型严格对齐）：
 *   - 输入：float32 [1,3,H,W]（NCHW），H=W=256（从模型读取，不写死）。
 *     预处理：中心方裁剪 → resize → ImageNet 风格归一化（mean/std 见下）。
 *   - 输出：单张热力图张量 [1, K, outH, outW]（K=24 个关键点，outH=outW=64）。
 *     若模型导出为「热力图 + 偏移」双输出（offset 形状 [1, K*2, outH, outW]），
 *     则启用 1/4 像素精修（offset 分支按存在性自动启用）。
 *   - 关键点顺序（24 点，本 App 业务侧唯一权威索引，PoseRules.kt 引用此表）：
 *       0 鼻 nose           1 左眼 left_eye       2 右眼 right_eye
 *       3 左耳根 left_ear   4 右耳根 right_ear     5 左耳尖 left_ear_tip
 *       6 右耳尖 right_ear_tip
 *       7 左前肩 l_shoulder 8 右前肩 r_shoulder
 *       9 左前肘 l_front_elbow 10 右前肘 r_front_elbow
 *       11 左前爪 l_front_paw 12 右前爪 r_front_paw
 *       13 左后髋 l_hip     14 右后髋 r_hip
 *       15 左后膝 l_back_knee 16 右后膝 r_back_knee
 *       17 左后爪 l_back_paw 18 右后爪 r_back_paw
 *       19 脊柱中段 spine（背线中点） 20 尾根 tail_base 21 尾中 tail_mid
 *       22 尾尖 tail_tip    23 颈 neck
 *
 *   ⚠️ 导出模型的关键点顺序若与上表不同，只需改本文件的 KPT_NAMES 顺序与
 *      PoseRules 的索引常量，业务判定公式无需变动。
 *
 *   - 置信度：取该点热力图峰值（0-1）。INT8 模型经 TFLite 自动反量化后返回 float。
 *     阈值 0.3（低于该值的点判无效，不参与判定）。
 */
class PoseEstimator private constructor(
    private val interpreter: org.tensorflow.lite.Interpreter
) {
    companion object {
        private const val TAG = "PoseInfer"
        const val K = 24                       // 关键点数量
        private const val CONF_THRESHOLD = 0.3f // 关键点置信阈值

        /** ImageNet 归一化参数（HRNet 主干通常为 ImageNet 预训练） */
        private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
        private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
        private const val SCALE_0_1 = 255f

        /** 24 关键点名称（顺序即模型输出顺序，业务侧引用） */
        val KPT_NAMES = arrayOf(
            "nose", "eye_l", "eye_r", "ear_base_l", "ear_base_r",
            "ear_tip_l", "ear_tip_r", "shoulder_l", "shoulder_r",
            "elbow_l", "elbow_r", "paw_front_l", "paw_front_r",
            "hip_l", "hip_r", "knee_back_l", "knee_back_r",
            "paw_back_l", "paw_back_r", "spine", "tail_base",
            "tail_mid", "tail_tip", "neck"
        )

        fun load(modelPath: String): PoseEstimator {
            val opt = org.tensorflow.lite.Interpreter.Options().setNumThreads(4)
            val buffer = loadModelFile(modelPath)
            val itp = org.tensorflow.lite.Interpreter(buffer, opt)
            Log.i(TAG, "HRNet tflite loaded: $modelPath, inputs=${itp.inputTensorCount}, outputs=${itp.outputTensorCount}")
            return PoseEstimator(itp)
        }

        fun validateModel(modelPath: String): Boolean {
            val opt = org.tensorflow.lite.Interpreter.Options().setNumThreads(1)
            val itp = org.tensorflow.lite.Interpreter(loadModelFile(modelPath), opt)
            val shape = itp.getInputTensor(0).shape()
            itp.close()
            Log.d(TAG, "validate OK, input shape=${shape.contentToString()}")
            return true
        }

        private fun loadModelFile(path: String): MappedByteBuffer {
            val f = java.io.File(path)
            java.io.FileInputStream(f).channel.use { ch ->
                return ch.map(FileChannel.MapMode.READ_ONLY, 0, f.length())
            }
        }
    }

    /** 一次推理结果 */
    data class PoseResult(
        val conf: Float,                  // 全图最高关键点等效置信度
        val box: FloatArray,              // [x1,y1,x2,y2] 关键点外接框（归一化）
        val kpts: FloatArray,             // K×3 = x,y,conf（归一化坐标）
    )

    fun close() {
        try { interpreter.close() } catch (_: Exception) {}
    }

    /**
     * 对一张 Bitmap 做推理。HRNet 是 top-down：整图缩放即可（宠物通常占主体）。
     * @return 关键点集；整体低于阈值返回 null（=识别失败，供上层降级）
     */
    fun detect(bitmap: Bitmap): PoseResult? {
        val inShape = interpreter.getInputTensor(0).shape() // [1,3,H,W]
        val inH = inShape[2]; val inW = inShape[3]
        val input = preprocess(bitmap, inW, inH)

        val outCount = interpreter.outputTensorCount
        val outShapes = Array(outCount) { interpreter.getOutputTensor(it).shape() }
        // 输出：热力图 [1,K,oH,oW]；若双输出，第二为 offset [1,K*2,oH,oW]
        val outputs = Array(outCount) { i ->
            val s = outShapes[i]
            Array(s[0]) { Array(s[1]) { FloatArray(s[2]) } }
        }
        val outputsMap = HashMap<Int, Any>()
        for (i in outputs.indices) outputsMap[i] = outputs[i]
        interpreter.runForMultipleInputsOutputs(arrayOf(input), outputsMap)

        val heat = outputs[0][0]           // [K, oW, oW]  (oH==oW)
        val hasOffset = outCount >= 2
        val offset = if (hasOffset) outputs[1][0] else null // [K*2, oW, oW]

        return parseHeatmaps(heat, offset, bitmap.width, bitmap.height, inW, inH)
    }

    /** 中心方裁剪 → resize → ImageNet 归一化 → NCHW float32 */
    private fun preprocess(src: Bitmap, dstW: Int, dstH: Int): ByteBuffer {
        val side = minOf(src.width, src.height)
        val dx = (src.width - side) / 2
        val dy = (src.height - side) / 2
        val square = Bitmap.createBitmap(src, dx, dy, side, side)
        val scaled = Bitmap.createScaledBitmap(square, dstW, dstH, true)

        val px = IntArray(dstW * dstH)
        scaled.getPixels(px, 0, dstW, 0, 0, dstW, dstH)
        val plane = dstW * dstH
        val buf = ByteBuffer.allocateDirect(plane * 3 * 4).order(ByteOrder.nativeOrder())
        val r = FloatArray(plane); val g = FloatArray(plane); val b = FloatArray(plane)
        for (i in px.indices) {
            val v = px[i]
            r[i] = (((v shr 16) and 0xFF).toFloat() / SCALE_0_1 - MEAN[0]) / STD[0]
            g[i] = (((v shr 8) and 0xFF).toFloat() / SCALE_0_1 - MEAN[1]) / STD[1]
            b[i] = ((v and 0xFF).toFloat() / SCALE_0_1 - MEAN[2]) / STD[2]
        }
        for (i in 0 until plane) buf.putFloat(r[i])
        for (i in 0 until plane) buf.putFloat(g[i])
        for (i in 0 until plane) buf.putFloat(b[i])
        buf.rewind()
        return buf
    }

    /**
     * 热力图解析：每个关键点在 oH×oW 平面取 argmax → 1/4 像素精修 → 归一到原图 0-1。
     * 若 offset 存在：x += offset[k]/oH，y += offset[k+K]/oW（归一化偏移）。
     * 置信度 = 热点峰值（0-1）。无效点（<阈值）坐标保留但 conf=0。
     */
    private fun parseHeatmaps(
        heat: Array<FloatArray>, offset: Array<FloatArray>?,
        origW: Int, origH: Int, inW: Int, inH: Int
    ): PoseResult? {
        val k = heat.size
        if (k == 0) { Log.w(TAG, "empty heatmap output"); return null }
        val res = heat[0].size // oH == oW（正方形输出）

        val kpts = FloatArray(K * 3)
        var bestConf = 0f
        var minX = 1f; var minY = 1f; var maxX = 0f; var maxY = 0f
        var valid = 0
        for (i in 0 until k) {
            var topY = 0; var topX = 0; var peak = -1f
            for (y in 0 until res) {
                for (x in 0 until res) {
                    val v = heat[i][y * res + x]
                    if (v > peak) { peak = v; topX = x; topY = y }
                }
            }
            val conf = peak.coerceIn(0f, 1f)
            // 1/4 像素精修（基于峰值邻域重心，无 offset 时）
            var fx = topX.toFloat(); var fy = topY.toFloat()
            if (offset != null && offset.size >= 2 * k) {
                fx += offset[i][topY * res + topX]      // x 偏移（已归一化到 /res）
                fy += offset[i + k][topY * res + topX]
            } else {
                // 简单二阶差分精修
                val xm = if (topX > 0) heat[i][topY * res + topX - 1] else peak
                val xp = if (topX < res - 1) heat[i][topY * res + topX + 1] else peak
                val ym = if (topY > 0) heat[i][(topY - 1) * res + topX] else peak
                val yp = if (topY < res - 1) heat[i][(topY + 1) * res + topX] else peak
                fx += 0.25f * (if (peak > 0f) (xp - xm) / (peak * 2f) else 0f)
                fy += 0.25f * (if (peak > 0f) (yp - ym) / (peak * 2f) else 0f)
            }
            val kx = (fx / res).coerceIn(0f, 1f)
            val ky = (fy / res).coerceIn(0f, 1f)
            val eff = if (conf < CONF_THRESHOLD) 0f else conf
            kpts[i * 3] = kx; kpts[i * 3 + 1] = ky; kpts[i * 3 + 2] = eff
            if (eff > 0f) {
                valid++; if (bestConf < eff) bestConf = eff
                minX = minOf(minX, kx); maxX = maxOf(maxX, kx)
                minY = minOf(minY, ky); maxY = maxOf(maxY, ky)
            }
        }
        Log.d(TAG, "parse heatmaps: kpts=$k valid=$valid bestConf=%.3f".format(bestConf))
        // 至少 8 个有效点且最高置信度达标，否则判失败
        if (valid < 8 || bestConf < CONF_THRESHOLD) {
            Log.i(TAG, "no pet above threshold: valid=$valid best=$bestConf")
            return null
        }
        return PoseResult(bestConf, floatArrayOf(minX, minY, maxX, maxY), kpts)
    }
}
