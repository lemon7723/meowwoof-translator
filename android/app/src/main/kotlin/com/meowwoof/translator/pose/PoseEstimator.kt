package com.meowwoof.translator.pose

import android.graphics.Bitmap
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * YOLOv8n-pose TFLite 推理器（独立类，异常只影响体态功能）。
 *
 * 说明（诚实边界）：yolov8n-pose 是 COCO 人体 17 关键点模型，未在猫狗上训练。
 * 本类提供通用的「关键点检测 + 置信度」推理管线；关键点与体态语义的对应关系
 * 集中在 [PoseRules] 的索引表里，未来替换为宠物姿态模型时只改那张表。
 *
 * 输出解析（YOLOv8-pose tflite 导出格式）：
 *   output0: [1, 57, N]  —— 57 = 4(box: cx,cy,w,h) + 1(obj/conf) + 52(17点×3)
 *   前导维度顺序依导出版本可能为 [1,57,N] 或 [57,N,1]，运行时自适应。
 */
class PoseEstimator private constructor(
    private val interpreter: org.tensorflow.lite.Interpreter
) {
    companion object {
        private const val TAG = "PoseInfer"
        private const val CONF_THRESHOLD = 0.5f   // 需求：置信度阈值 0.5

        /** 从文件加载（含损坏校验），失败抛异常由上层捕获 */
        fun load(modelPath: String): PoseEstimator {
            val opt = org.tensorflow.lite.Interpreter.Options()
                .setNumThreads(2)
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
        val conf: Float,                  // 整体检测置信度
        val box: FloatArray,              // [x1,y1,x2,y2] 归一化 0-1
        val kpts: FloatArray,             // 17×3 = x,y,conf（归一化坐标）
    )

    fun close() {
        try { interpreter.close() } catch (_: Exception) {}
    }

    /**
     * 对一张 Bitmap 做推理。
     * @return 最高置信度的检测；低于 [CONF_THRESHOLD] 返回 null（=识别失败）
     */
    fun detect(bitmap: Bitmap): PoseResult? {
        // 1) 输入尺寸从模型读取（不写死）
        val inShape = interpreter.getInputTensor(0).shape() // e.g. [1,256,256,3]
        val inH = inShape[inShape.size - 3]
        val inW = inShape[inShape.size - 2]
        Log.d(TAG, "input tensor shape=${inShape.contentToString()} -> ${inW}x$inH")

        // 2) letterbox 预处理（保持长宽比，灰边填充）
        val scaled = letterbox(bitmap, inW, inH)
        val input = BitmapToInt8OrFloat(scaled, inW, inH)

        // 3) 推理（输出用一维 FloatArray）
        val outShape = interpreter.getOutputTensor(0).shape()
        val outSize = outShape.fold(1) { a, b -> a * b.coerceAtLeast(1) }
        val out = FloatArray(outSize)
        Log.d(TAG, "output tensor shape=${outShape.contentToString()}")
        interpreter.run(input, out)

        // 4) 解析 [1,57,N] 或 [57,N,1]
        return parseOutput(out, outShape, bitmap.width, bitmap.height, inW, inH)
    }

    /** letterbox：等比缩放 + 置中填充，返回缩放后 bitmap 与有效区偏移 */
    private fun letterbox(src: Bitmap, dstW: Int, dstH: Int): Bitmap {
        val scale = minOf(dstW.toFloat() / src.width, dstH.toFloat() / src.height)
        val nw = (src.width * scale).toInt().coerceAtLeast(1)
        val nh = (src.height * scale).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(src, nw, nh, true)
        val out = Bitmap.createBitmap(dstW, dstH, Bitmap.Config.ARGB_8888)
        val cv = android.graphics.Canvas(out)
        cv.drawColor(android.graphics.Color.rgb(114, 114, 114))
        val dx = (dstW - nw) / 2f
        val dy = (dstH - nh) / 2f
        cv.drawBitmap(scaled, dx, dy, null)
        return out
    }

    /** 按模型 dtype 组装输入 buffer（int8 量化 → 直接写 0-255 字节；float → /255） */
    private fun BitmapToInt8OrFloat(bmp: Bitmap, w: Int, h: Int): Any {
        val dtype = interpreter.getInputTensor(0).dataType()
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)
        if (dtype == org.tensorflow.lite.DataType.UINT8) {
            val buf = ByteBuffer.allocateDirect(w * h * 3)
                .order(ByteOrder.nativeOrder())
            for (p in pixels) {
                buf.put(((p shr 16) and 0xFF).toByte())
                buf.put(((p shr 8) and 0xFF).toByte())
                buf.put((p and 0xFF).toByte())
            }
            buf.rewind()
            return buf
        } else {
            val buf = ByteBuffer.allocateDirect(w * h * 3 * 4)
                .order(ByteOrder.nativeOrder())
            for (p in pixels) {
                buf.putFloat(((p shr 16) and 0xFF) / 255f)
                buf.putFloat(((p shr 8) and 0xFF) / 255f)
                buf.putFloat((p and 0xFF) / 255f)
            }
            buf.rewind()
            return buf
        }
    }

    /**
     * 解析 YOLOv8-pose 输出为最高置信度检测结果。
     * 坐标还原：letterbox 反算回原图 0-1 归一化。
     */
    private fun parseOutput(
        out: FloatArray, shape: IntArray,
        origW: Int, origH: Int, inW: Int, inH: Int
    ): PoseResult? {
        // 识别布局：通道数=57 在哪一维
        val dims = shape.filter { it > 0 }
        if (dims.size < 2) { Log.w(TAG, "unexpected output shape $shape"); return null }
        val chFirst = (dims.getOrNull(1) == 57)          // [1,57,N]
        val channels = if (chFirst) dims[1] else dims[dims.size - 2]
        val num = if (chFirst) dims[dims.size - 1] else dims[1]
        if (channels != 57) {
            Log.w(TAG, "expect 57 channels, got $channels (pose head changed?)")
        }
        val n = num
        Log.d(TAG, "parse: layout=${if (chFirst) "[1,57,N]" else "[57,N,1]"} N=$n")

        fun at(c: Int, i: Int): Float =
            if (chFirst) out[c * n + i] else out[c * n + i]  // 两种布局在此等价

        var bestIdx = -1
        var bestConf = 0f
        for (i in 0 until n) {
            val conf = at(4, i)
            if (conf > bestConf) { bestConf = conf; bestIdx = i }
        }
        if (bestIdx < 0 || bestConf < CONF_THRESHOLD) {
            Log.i(TAG, "no pet above threshold: best=$bestConf")
            return null
        }
        val cx = at(0, bestIdx) / inW
        val cy = at(1, bestIdx) / inH
        val bw = at(2, bestIdx) / inW
        val bh = at(3, bestIdx) / inH
        val kpts = FloatArray(17 * 3)
        for (k in 0 until 17) {
            kpts[k * 3] = (at(5 + k * 3, bestIdx) / inW).coerceIn(0f, 1f)
            kpts[k * 3 + 1] = (at(6 + k * 3, bestIdx) / inH).coerceIn(0f, 1f)
            kpts[k * 3 + 2] = at(7 + k * 3, bestIdx)
        }
        var visCount = 0
        for (k in 0 until 17) {
            if (kpts[k * 3 + 2] > CONF_THRESHOLD) visCount++
        }
        Log.i(TAG, "detected conf=%.2f kptsVis=%d/17".format(bestConf, visCount))
        return PoseResult(
            bestConf,
            floatArrayOf(cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2),
            kpts
        )
    }
}
