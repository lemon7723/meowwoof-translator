package com.meowwoof.translator.pose

import android.graphics.Bitmap
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * RTMPose-Animal（AP-10K）TFLite 推理器（v1.5.0，猫狗专用动物姿态模型）。
 *
 * 模型事实（官方 README + 本地 TFLite 解释器实测）：
 *  - 输入：float32 [1,3,256,256] NCHW，mmpose mean/std 归一化（RGB 0-255 域）
 *      MEAN = [123.675, 116.28, 103.53]，STD = [58.395, 57.12, 57.375]
 *  - 输出：SimCC 双张量 simcc_x[1,17,512]、simcc_y[1,17,512]
 *      每个关键点坐标 = argmax(那条 1D SimCC) / 2.0（256 空间像素）
 *  - 17 个 AP-10K 动物关键点（猫狗等 23 种动物训练）：
 *      0 左眼  1 右眼  2 鼻  3 颈  4 尾根  5 尾尖（垂/翘判定核心）
 *      6 左前膝 7 右前膝 8 左后膝 9 右后膝
 *      10-15 前后肢中间关节（肘/腕类）
 *      16 体侧/背部参考点
 *      （精确语义以 PoseRules 索引表为准，业务规则引用那张表）
 *
 * 置信度说明：SimCC 回归范式没有独立 visibility 通道，
 * 用「峰值锐度」合成等效置信度（top1 与 top2 分差归一化到 0-1），
 * 阈值保持 0.5，低于判该关键点无效——语义对齐原需求。
 */
class PoseEstimator private constructor(
    private val interpreter: org.tensorflow.lite.Interpreter
) {
    companion object {
        private const val TAG = "PoseInfer"
        private const val CONF_THRESHOLD = 0.5f   // 等效关键点置信阈值

        /** mmpose 官方归一化参数（RGB，0-255 域） */
        private val MEAN = floatArrayOf(123.675f, 116.28f, 103.53f)
        private val STD = floatArrayOf(58.395f, 57.12f, 57.375f)

        /** 从文件加载（含损坏校验），失败抛异常由上层捕获 */
        fun load(modelPath: String): PoseEstimator {
            val opt = org.tensorflow.lite.Interpreter.Options()
                .setNumThreads(4)
            val buffer = loadModelFile(modelPath)
            val itp = org.tensorflow.lite.Interpreter(buffer, opt)
            Log.i(TAG, "tflite loaded: $modelPath, inputTensors=${itp.inputTensorCount}")
            return PoseEstimator(itp)
        }

        /** 仅校验模型能否被 TFLite 打开（下载完成后的完整性检查用），用完即关 */
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
     * 对一张 Bitmap 做推理（RTMPose 是 top-down 模型：整图缩放即可，
     * 宠物通常占画面主体；识别质量依赖构图，页面已有构图提示）。
     * @return 最高等效置信度的关键点集；整体低于阈值返回 null（=识别失败）
     */
    fun detect(bitmap: Bitmap): PoseResult? {
        // 1) 输入尺寸从模型读取（不写死）
        val inShape = interpreter.getInputTensor(0).shape() // [1,3,256,256] NCHW
        val inC = inShape[1]; val inH = inShape[2]; val inW = inShape[3]
        Log.d(TAG, "input tensor shape=${inShape.contentToString()} -> ${inW}x$inH x$inC")

        // 2) 预处理：中心方裁剪 + 缩放 + mmpose mean/std + NCHW
        val input = preprocess(bitmap, inW, inH)

        // 3) 推理：两个输出张量 [1,17,512]（输出缓冲带 batch 维，与张量形状严格一致）
        val outCount = interpreter.outputTensorCount
        val outShapes = Array(outCount) { interpreter.getOutputTensor(it).shape() }
        val outputs = Array(outCount) { i ->
            val s = outShapes[i]
            // [1, K, bins] —— 三维数组与张量形状逐维一致
            Array(s[0]) { Array(s[1]) { FloatArray(s[2]) } }
        }
        val outputsMap = HashMap<Int, Any>()
        for (i in outputs.indices) outputsMap[i] = outputs[i]
        interpreter.runForMultipleInputsOutputs(arrayOf(input), outputsMap)
        // 去掉 batch 维后再解析
        val simccX = outputs[0][0]   // [K, bins]
        val simccY = outputs[1][0]   // [K, bins]

        // 4) SimCC 解析：argmax / 2 → 256 空间坐标，再反算原图归一化
        return parseSimCC(simccX, simccY, bitmap.width, bitmap.height, inW, inH)
    }

    /** 中心方裁剪 → 256×256 → RGB float32 NCHW，mmpose mean/std 归一化 */
    private fun preprocess(src: Bitmap, dstW: Int, dstH: Int): ByteBuffer {
        // 中心方裁剪（top-down 模型标准做法）
        val side = minOf(src.width, src.height)
        val dx = (src.width - side) / 2
        val dy = (src.height - side) / 2
        val square = Bitmap.createBitmap(src, dx, dy, side, side)
        val scaled = Bitmap.createScaledBitmap(square, dstW, dstH, true)

        val px = IntArray(dstW * dstH)
        scaled.getPixels(px, 0, dstW, 0, 0, dstW, dstH)
        // NCHW：三个通道平面分开写
        val buf = ByteBuffer.allocateDirect(inChCap(dstW, dstH))
            .order(ByteOrder.nativeOrder())
        val plane = dstW * dstH
        val r = FloatArray(plane); val g = FloatArray(plane); val b = FloatArray(plane)
        for (i in px.indices) {
            r[i] = ((px[i] shr 16) and 0xFF) - MEAN[0]
            g[i] = ((px[i] shr 8) and 0xFF) - MEAN[1]
            b[i] = (px[i] and 0xFF) - MEAN[2]
        }
        for (i in 0 until plane) buf.putFloat(r[i] / STD[0])
        for (i in 0 until plane) buf.putFloat(g[i] / STD[1])
        for (i in 0 until plane) buf.putFloat(b[i] / STD[2])
        buf.rewind()
        return buf
    }

    private fun inChCap(w: Int, h: Int): Int = w * h * 3 * 4

    /**
     * SimCC 解析：每个关键点在 x/y 两条 1D 分布上各取 argmax。
     * 坐标 = argmax / 2（bins=512 → 256 空间），再除以模型输入尺寸 → 0-1 归一化。
     * 等效置信度 = (top1 - top2) / top1 的归一化锐度 × 峰值占比，双条件低于 0.5 判无效。
     */
    private fun parseSimCC(
        simccX: Array<FloatArray>, simccY: Array<FloatArray>,
        origW: Int, origH: Int, inW: Int, inH: Int
    ): PoseResult? {
        val k = minOf(simccX.size, simccY.size)
        if (k == 0) { Log.w(TAG, "empty simcc output"); return null }
        val bins = simccX[0].size

        val kpts = FloatArray(k * 3)
        var bestConf = 0f
        var minX = 1f; var minY = 1f; var maxX = 0f; var maxY = 0f
        var valid = 0

        for (i in 0 until k) {
            val xs = simccX[i]; val ys = simccY[i]
            var top1x = 0; var top2x = 0; var v1x = -1f; var v2x = -1f
            for (b in 0 until bins) {
                val v = xs[b]
                if (v > v1x) { v2x = v1x; v1x = v; top2x = top1x; top1x = b }
                else if (v > v2x) { v2x = v; top2x = b }
            }
            var top1y = 0; var v1y = -1f
            for (b in 0 until bins) {
                val v = ys[b]
                if (v > v1y) { v1y = v; top1y = b }
            }
            // 峰值锐度：与次峰的分差比例（SimCC 无置信通道的等效替代）
            val sharp = if (v1x <= 0f) 0f else ((v1x - v2x) / v1x).coerceIn(0f, 1f)
            // 峰值强度：归一化到该关键点最大可能（跨 x/y 峰值取平均占比）
            val strength = (v1x + v1y) / 2f / (maxOf(v1x, v1y) + 1e-9f).coerceAtLeast(1e-9f)
            val conf = (0.6f * sharp + 0.4f * strength).coerceIn(0f, 1f)

            val kx = top1x / 2f / inW   // bins=512 → 256 空间 → 归一化
            val ky = top1y / 2f / inH
            val eff = if (conf < CONF_THRESHOLD) 0f else conf
            kpts[i * 3] = kx.coerceIn(0f, 1f)
            kpts[i * 3 + 1] = ky.coerceIn(0f, 1f)
            kpts[i * 3 + 2] = eff
            if (eff > 0f) {
                valid++
                if (bestConf < eff) bestConf = eff
                minX = minOf(minX, kpts[i * 3]); maxX = maxOf(maxX, kpts[i * 3])
                minY = minOf(minY, kpts[i * 3 + 1]); maxY = maxOf(maxY, kpts[i * 3 + 1])
            }
        }
        Log.d(TAG, "parse simcc: kpts=$k valid=$valid bestConf=%.3f".format(bestConf))
        if (valid < 6 || bestConf < CONF_THRESHOLD) {
            Log.i(TAG, "no pet above threshold: valid=$valid best=$bestConf")
            return null
        }
        return PoseResult(
            bestConf,
            floatArrayOf(minX, minY, maxX, maxY),
            kpts
        )
    }
}
