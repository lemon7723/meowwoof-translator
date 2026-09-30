package com.meowwoof.translator.pose

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.ImageReader
import android.media.Image
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.jvm.Synchronized
import kotlin.math.maxOf
import kotlin.math.min

/**
 * 相机捕获 + 实时姿态推理 + 音画同步录像 + 边录边叫（需求 4/5/8/8.1）。
 *
 * 架构（纯离线，无 Google 服务，x86_64 模拟器可跑）：
 *  - Camera2 仅把画面送到一个 ImageReader（YUV_420_888）。
 *  - 每帧回调里：① 计算平均亮度判断暗光；② YUV→Bitmap（旋转到竖屏）；
 *    ③ 手动把 Bitmap 画到 PlatformView(SurfaceView) 当实时预览；
 *    ④ 节流跑 SSD 前置检测（无宠物则跳过姿态）；⑤ 节流跑 HRNet 姿态推理→情绪；
 *    ⑥ 录像时把情绪文字烧录进 Bitmap→NV21→H.264 编码器。
 *  - 麦克风单独 AudioRecord → AAC 编码器；与 HRNet/SSD 同时并发运行。
 *  - 边录边叫：把预设叫声解码为 PCM，用 AudioTrack 放给扬声器（循环），
 *    同时把同一份 PCM 混入麦克风采样送进音频编码器（音画严格对齐）。
 *
 * ★ 本文件为"可在真机/模拟器跑起来的骨架"，下列项需真机实测微调（已注释标出）：
 *    - 录制分辨率/码率/帧率（captureW/H、BIT_RATE、FPS）；
 *    - 暗光阈值 LOW_LIGHT_LUMA；
 *    - 竖屏旋转角度 frameRotation（不同前后摄/厂商不同）；
 *    - 情绪文字在视频里的位置/字号（drawEmotionOverlay）。
 */
object CameraRecorder {

    private const val TAG = "CameraRec"
    private const val LOW_LIGHT_LUMA = 28f          // 平均亮度阈值（0-255），低于即暗光
    private const val NORMAL_FRAME_SKIP = 2          // 非低端机：每 2~3 帧推理一次
    private const val A13_FRAME_SKIP = 3             // A13/最低档：强制每 3 帧
    private const val SSD_FRAME_SKIP = 4             // SSD 前置检测节流
    private const val REC_FPS = 30
    private const val VIDEO_BITRATE = 2_000_000
    private const val AUDIO_SAMPLE_RATE = 16000
    private const val AUDIO_BITRATE = 64_000

    // —— 状态 ——
    private var ctx: Context? = null
    private var cameraManager: CameraManager? = null
    private var cameraId: String = "0"
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var captureW = 480
    private var captureH = 640
    private var frameRotation = 0                   // 把相机画面旋成竖屏所需角度

    private var postureEnabled = true
    private var isA13 = false
    @Volatile private var postureRunning = false

    private var estimator: PoseEstimator? = null
    private var ssd: SsdDetector? = null
    @Volatile private var hasPet = false
    @Volatile private var lowLight = false
    private var lastEmotion: String? = null
    private var lastDetail: String? = null
    private var frameCount = 0

    @Volatile private var previewSurface: Surface? = null

    // —— 线程 ——
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cameraThread = HandlerThread("cam-rec").also { it.start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val inferenceExecutor = Executors.newSingleThreadExecutor()

    // —— 事件通道（MainActivity 注入，用于回传 Dart）——
    private var eventChannel: MethodChannel? = null
    fun attachEventChannel(ch: MethodChannel) { eventChannel = ch }

    // —— 录制相关 ——
    @Volatile private var recording = false
    private var videoEncoder: MediaCodec? = null
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var muxer: MediaMuxer? = null
    private var videoTrackIdx = -1
    private var audioTrackIdx = -1
    private var muxerStarted = false
    private var videoEos = false
    private var audioEos = false
    private var videoPtsUs = 0L
    private var audioPtsUs = 0L
    private var outPath: String = ""
    private val recordThread = HandlerThread("rec-audio").also { it.start() }
    private val recordHandler = Handler(recordThread.looper)
    // 边录边叫的播放循环会阻塞，必须用独立线程跑，绝不能在主线程（MethodChannel 回调线程）
    private val callExecutor = Executors.newSingleThreadExecutor()

    // —— 边录边叫 ——
    private var callTrack: AudioTrack? = null
    @Volatile private var callShort: ShortArray? = null   // 已按 rate 重采样的播放 PCM
    @Volatile private var callLen = 0
    @Volatile private var callPos = 0
    @Volatile private var callActive = false

    // ====================================================================
    //  打开相机（Dart: VideoRecordService.open）
    // ====================================================================
    fun open(context: Context, postureEnabled: Boolean, isA13: Boolean): Boolean {
        this.ctx = context.applicationContext
        this.postureEnabled = postureEnabled
        this.isA13 = isA13
        val c = this.ctx ?: return false
        cameraManager = c.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        // 体态开启时才加载模型（需求 2 失败降级：不加载也不影响相机/音频）
        if (postureEnabled) {
            try {
                val mf = ModelDownloadManager.modelFile(c)
                if (mf.exists() && mf.length() > ModelDownloadManager.MIN_VALID_BYTES) {
                    estimator = PoseEstimator.load(mf.absolutePath)
                }
                ssd = SsdDetector.loadFromAssets(c)
            } catch (t: Throwable) {
                Log.e(TAG, "model load failed (degrade): ${t.message}")
            }
        }
        // 选后置摄像头
        cameraId = (cameraManager!!.cameraIdList.firstOrNull { id ->
            val facing = cameraManager!!.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING)
            facing == CameraCharacteristics.LENS_FACING_BACK
        } ?: cameraManager!!.cameraIdList.firstOrNull()) ?: return false

        val chars = cameraManager!!.getCameraCharacteristics(cameraId)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.YUV_420_888) ?: arrayOf(Size(480, 640))
        val chosen = chooseSize(sizes)
        captureW = chosen.width; captureH = chosen.height
        // 横构图则旋 90° 成竖屏（模拟器/真机通用近似；真机实测可改）
        frameRotation = if (captureW > captureH) 90 else 0

        imageReader = ImageReader.newInstance(captureW, captureH, ImageFormat.YUV_420_888, 3)
        imageReader!!.setOnImageAvailableListener({ onImageAvailable() }, cameraHandler)

        if (ContextCompat.checkSelfPermission(c, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "no camera permission")
            return false
        }
        try {
            cameraManager!!.openCamera(cameraId, stateCallback, cameraHandler)
        } catch (t: CameraAccessException) {
            Log.e(TAG, "openCamera failed: ${t.message}")
            return false
        }
        return true
    }

    private val stateCallback = object : CameraDevice.StateCallback() {
        override fun onOpened(device: CameraDevice) {
            cameraDevice = device
            startSession()
        }
        override fun onDisconnected(device: CameraDevice) { device.close(); cameraDevice = null }
        override fun onError(device: CameraDevice, error: Int) {
            Log.e(TAG, "camera error $error"); device.close(); cameraDevice = null
        }
    }

    private fun startSession() {
        val dev = cameraDevice ?: return
        val surf = imageReader?.surface ?: return
        val req = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
        req.addTarget(surf)
        try {
            dev.createCaptureSession(listOf(surf), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    try {
                        session.setRepeatingRequest(req.build(), null, cameraHandler)
                    } catch (t: Throwable) { Log.e(TAG, "repeating failed: ${t.message}") }
                }
                override fun onConfigureFailed(session: CameraCaptureSession) {
                    Log.e(TAG, "session configure failed")
                }
            }, cameraHandler)
        } catch (t: Throwable) { Log.e(TAG, "createCaptureSession failed: ${t.message}") }
    }

    /** 从可用尺寸里挑最接近 480x640 且边长≥480 的（竖屏优先） */
    private fun chooseSize(sizes: Array<Size>): Size {
        if (sizes.isEmpty()) return Size(480, 640)
        var best = sizes[0]; var bestScore = Int.MAX_VALUE
        for (s in sizes) {
            val area = s.width * s.height
            // 偏好竖屏(高≥宽)且边长≥480，面积接近 480*640=307200
            val portraitPenalty = if (s.height >= s.width) 0 else 200_000
            val score = kotlin.math.abs(area - 307_200) + portraitPenalty
            if (score < bestScore &&
                min(s.width, s.height) >= 480) {
                best = s; bestScore = score
            }
        }
        return best
    }

    // ====================================================================
    //  预览 Surface 绑定（PlatformView 生命周期）
    // ====================================================================
    fun attachPreview(surface: Surface) {
        previewSurface = surface
        Log.i(TAG, "preview surface attached")
    }
    fun detachPreview(view: android.view.View) {
        // 仅一个预览视图，直接清空（解除引用，避免向已销毁 Surface 绘制）
        previewSurface = null
        Log.i(TAG, "preview surface detached")
    }

    // ====================================================================
    //  实时帧处理
    // ====================================================================
    private fun onImageAvailable() {
        val reader = imageReader ?: return
        var image: Image? = null
        try { image = reader.acquireLatestImage() } catch (_: Throwable) {}
        if (image == null) return
        try {
            frameCount++
            // ① 暗光检测（用 Y 平面抽样平均亮度）
            val luma = averageLuma(image)
            lowLight = luma < LOW_LIGHT_LUMA
            // ② YUV → 竖屏 Bitmap（每帧一次，供预览/推理/录像复用）
            val bmp = yuvToBitmap(image, frameRotation)
            image.close()

            // ③ 实时预览绘制
            drawPreview(bmp)

            // ④⑤ 体态推理（暗光或关闭时跳过）
            if (!lowLight && postureEnabled) {
                if (!postureRunning) postureRunning = true
                val doSsd = ssd != null && frameCount % SSD_FRAME_SKIP == 0
                if (doSsd) hasPet = ssd!!.detect(bmp)
                val skip = if (isA13) A13_FRAME_SKIP else NORMAL_FRAME_SKIP
                if (frameCount % skip == 0) {
                    if (ssd == null || hasPet) {
                        val r = estimator?.detect(bmp)
                        val emo = if (r != null) PoseRules.judge("cat", r.kpts) else null
                        lastEmotion = emo?.label
                        lastDetail = emo?.detail
                    } else {
                        lastEmotion = null; lastDetail = null
                    }
                }
            } else {
                if (postureRunning) postureRunning = false
                lastEmotion = null; lastDetail = null
            }

            // ⑥ 录像（带情绪文字烧录）
            if (recording) encodeFrame(bmp, lastEmotion)

            emitIfChanged()
            bmp.recycle()
        } catch (t: Throwable) {
            Log.e(TAG, "onImageAvailable error: ${t.message}")
            try { image.close() } catch (_: Throwable) {}
        }
    }

    private fun averageLuma(image: Image): Float {
        val plane = image.planes[0]
        val buf = plane.buffer
        val rowStride = plane.rowStride
        var sum = 0L; var n = 0
        val h = image.height; val w = image.width
        // 抽样（每 8 行/列）以降开销
        var y = 0
        while (y < h) {
            var x = 0
            while (x < w) {
                val v = buf.get(y * rowStride + x).toInt() and 0xFF
                sum += v; n++
                x += 8
            }
            y += 8
        }
        return if (n > 0) sum.toFloat() / n else 255f
    }

    /** YUV_420_888 → 竖屏旋转后的 ARGB Bitmap（通用 stride 兼容） */
    private fun yuvToBitmap(image: Image, rotation: Int): Bitmap {
        val w = image.width; val h = image.height
        val planes = image.planes
        val yBuf = planes[0].buffer; val yRow = planes[0].rowStride
        val uBuf = planes[1].buffer; val uRow = planes[1].rowStride; val uPix = planes[1].pixelStride
        val vBuf = planes[2].buffer; val vRow = planes[2].rowStride; val vPix = planes[2].pixelStride
        val argb = IntArray(w * h)
        var idx = 0
        for (j in 0 until h) {
            val yRowOff = j * yRow
            val uvRow = (j shr 1) * uRow
            val uvRowV = (j shr 1) * vRow
            for (i in 0 until w) {
                val y = (yBuf.get(yRowOff + i).toInt() and 0xFF) - 16
                val u = (uBuf.get(uvRow + (i shr 1) * uPix).toInt() and 0xFF) - 128
                val v = (vBuf.get(uvRowV + (i shr 1) * vPix).toInt() and 0xFF) - 128
                argb[idx++] = yuv2rgb(y, u, v)
            }
        }
        val src = Bitmap.createBitmap(argb, w, h, Bitmap.Config.ARGB_8888)
        if (rotation == 0) return src
        val m = Matrix().apply { postRotate(rotation.toFloat()) }
        return Bitmap.createBitmap(src, 0, 0, w, h, m, true).also { src.recycle() }
    }

    private fun yuv2rgb(y: Int, u: Int, v: Int): Int {
        var r = (y * 1192 + v * 1634 + 2048) shr 12
        var g = (y * 1192 - u * 400 - v * 832 + 2048) shr 12
        var b = (y * 1192 + u * 2066 + 2048) shr 12
        r = r.coerceIn(0, 255); g = g.coerceIn(0, 255); b = b.coerceIn(0, 255)
        return (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private fun drawPreview(bmp: Bitmap) {
        val surf = previewSurface ?: return
        var canvas: Canvas? = null
        try {
            canvas = surf.lockCanvas(null)
        } catch (_: Throwable) { return }
        if (canvas == null) return
        try {
            val cw = canvas.width; val ch = canvas.height
            val scale = min(cw.toFloat() / bmp.width, ch.toFloat() / bmp.height)
            val dw = bmp.width * scale; val dh = bmp.height * scale
            val dx = (cw - dw) / 2f; val dy = (ch - dh) / 2f
            canvas.drawColor(Color.BLACK)
            canvas.drawBitmap(bmp, null, android.graphics.RectF(dx, dy, dx + dw, dy + dh), null)
        } finally {
            try { surf.unlockCanvasAndPost(canvas) } catch (_: Throwable) {}
        }
    }

    // ====================================================================
    //  开始/停止实时姿态推理
    // ====================================================================
    fun startPosture() { postureRunning = postureEnabled && !lowLight }
    fun stopPosture() { postureRunning = false }

    // ====================================================================
    //  音画同步录像（需求 8）
    // ====================================================================
    fun startRecord(): Boolean {
        if (recording) return true
        val c = ctx ?: return false
        val outDir = File(c.cacheDir, "meowwoof_videos")
        if (!outDir.exists()) outDir.mkdirs()
        outPath = File(outDir, "pet_mood_${System.currentTimeMillis()}.mp4").absolutePath
        try {
            videoEncoder = MediaCodec.createEncoderByType("video/avc")
            val vfmt = MediaFormat.createVideoFormat("video/avc", captureW, captureH)
            vfmt.setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_BITRATE)
            vfmt.setInteger(MediaFormat.KEY_FRAME_RATE, REC_FPS)
            vfmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            vfmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            videoEncoder!!.configure(vfmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            videoEncoder!!.start()

            audioEncoder = MediaCodec.createEncoderByType("audio/mp4a-latm")
            val afmt = MediaFormat.createAudioFormat("audio/mp4a-latm", AUDIO_SAMPLE_RATE, 1)
            afmt.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            afmt.setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BITRATE)
            audioEncoder!!.configure(afmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            audioEncoder!!.start()

            muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            videoTrackIdx = -1; audioTrackIdx = -1; muxerStarted = false
            videoEos = false; audioEos = false
            videoPtsUs = 0L; audioPtsUs = 0L

            // 麦克风（独立 AudioRecord，与 Vosk 识别互不干扰）
            val minBuf = AudioRecord.getMinBufferSize(AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            audioRecord = AudioRecord(android.media.MediaRecorder.AudioSource.MIC,
                AUDIO_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, AUDIO_SAMPLE_RATE))
            audioRecord!!.startRecording()

            recording = true
            recordHandler.post { audioEncodeLoop() }
            emitRecordState(true)
            Log.i(TAG, "record started -> $outPath")
            return true
        } catch (t: Throwable) {
            Log.e(TAG, "startRecord failed: ${t.message}")
            cleanupRecord()
            return false
        }
    }

    fun stopRecord(): Map<String, Any?> {
        recording = false
        callActive = false
        try { callTrack?.stop() } catch (_: Throwable) {}
        try { callTrack?.release() } catch (_: Throwable) {}
        callTrack = null
        // 立即停止录像，但"等编码器吐完剩余帧 + 释放资源"放到后台线程，
        // 避免在主线程（MethodChannel 回调线程）sleep/释放导致 UI 卡顿。
        // audioEncodeLoop 同样跑在 recordHandler 上，两者串行不会并发释放编码器。
        val result = mapOf("path" to outPath)
        recordHandler.post {
            try { Thread.sleep(200) } catch (_: Throwable) {}
            cleanupRecord()
            emitRecordState(false)
            Log.i(TAG, "record stopped -> $outPath")
        }
        return result
    }

    private fun cleanupRecord() {
        try { audioRecord?.stop() } catch (_: Throwable) {}
        try { audioRecord?.release() } catch (_: Throwable) {}
        audioRecord = null
        try { videoEncoder?.stop() } catch (_: Throwable) {}
        try { videoEncoder?.release() } catch (_: Throwable) {}
        videoEncoder = null
        try { audioEncoder?.stop() } catch (_: Throwable) {}
        try { audioEncoder?.release() } catch (_: Throwable) {}
        audioEncoder = null
        if (muxerStarted) { try { muxer?.stop() } catch (_: Throwable) {} }
        try { muxer?.release() } catch (_: Throwable) {}
        muxer = null; muxerStarted = false
    }

    /** 视频帧编码：Bitmap→NV21→编码器；情绪文字烧录在 Bitmap 上 */
    private fun encodeFrame(bmp: Bitmap, emotion: String?) {
        val enc = videoEncoder ?: return
        val draw = if (emotion != null) drawEmotionOverlay(bmp, emotion) else bmp
        val nv21 = bitmapToNv21(draw)
        if (draw !== bmp) draw.recycle()
        val inIdx = try { enc.dequeueInputBuffer(10_000) } catch (_: Throwable) { -1 }
        if (inIdx >= 0) {
            val inp = enc.getInputBuffer(inIdx) ?: return
            inp.clear(); inp.put(nv21)
            enc.queueInputBuffer(inIdx, 0, nv21.size, videoPtsUs, 0)
            videoPtsUs += 1_000_000L / REC_FPS
        }
        drainEncoder(enc, false, true)
    }

    /** 把情绪文字画到拷贝 Bitmap 上，返回拷贝（需调用方 recycle） */
    private fun drawEmotionOverlay(bmp: Bitmap, text: String): Bitmap {
        val out = Bitmap.createBitmap(bmp.width, bmp.height, bmp.config ?: Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawBitmap(bmp, 0f, 0f, null)
        val paint = Paint().apply {
            color = Color.WHITE
            textSize = (bmp.width * 0.06f).coerceAtLeast(18f)
            setShadowLayer(4f, 2f, 2f, Color.BLACK)
            isAntiAlias = true
        }
        c.drawText("Pet Mood: $text", 24f, (bmp.height - 24f), paint)
        return out
    }

    /** ARGB Bitmap → NV21（YUV420 半平面，V 在前 U 在后） */
    private fun bitmapToNv21(bmp: Bitmap): ByteArray {
        val w = bmp.width; val h = bmp.height
        val px = IntArray(w * h); bmp.getPixels(px, 0, w, 0, 0, w, h)
        val yuv = ByteArray(w * h + (w * h) / 2)
        var yIdx = 0; var vuIdx = w * h
        for (j in 0 until h) {
            for (i in 0 until w) {
                val p = px[j * w + i]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                yuv[yIdx++] = y.coerceIn(0, 255).toByte()
                if (j % 2 == 0 && i % 2 == 0) {
                    val u = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val v = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    yuv[vuIdx++] = v.coerceIn(0, 255).toByte()
                    yuv[vuIdx++] = u.coerceIn(0, 255).toByte()
                }
            }
        }
        return yuv
    }

    /** 音频线程：麦克风→AAC，混入选中叫声 PCM */
    private fun audioEncodeLoop() {
        val enc = audioEncoder ?: return
        val rec = audioRecord ?: return
        val bufSize = 2048
        val pcm = ShortArray(bufSize)
        while (recording) {
            val n = rec.read(pcm, 0, bufSize)
            if (n <= 0) continue
            // 混入叫声（边录边叫）
            if (callActive) {
                val cs = callShort
                if (cs != null && callLen > 0) {
                    for (i in 0 until n) {
                        val s = (pcm[i] + cs[callPos]) / 2
                        pcm[i] = s.coerceIn(-32768, 32767).toShort()
                        callPos++
                        if (callPos >= callLen) callPos = 0
                    }
                }
            }
            val inIdx = try { enc.dequeueInputBuffer(10_000) } catch (_: Throwable) { -1 }
            if (inIdx >= 0) {
                val inp = enc.getInputBuffer(inIdx) ?: continue
                inp.clear()
                val bytes = shortToBytes(pcm, n)
                inp.put(bytes)
                enc.queueInputBuffer(inIdx, 0, bytes.size, audioPtsUs, 0)
                audioPtsUs += (n.toLong() * 1_000_000L / AUDIO_SAMPLE_RATE)
            }
            drainEncoder(enc, false, false)
        }
        // 收尾：EOS
        try {
            val inIdx = enc.dequeueInputBuffer(10_000)
            if (inIdx >= 0) enc.queueInputBuffer(inIdx, 0, 0, audioPtsUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        } catch (_: Throwable) {}
        drainEncoder(enc, true, false)
    }

    @Synchronized
    private fun drainEncoder(enc: MediaCodec, eos: Boolean, isVideo: Boolean): Int {
        val info = MediaCodec.BufferInfo()
        var idx = 0
        try {
            while (true) {
                idx = enc.dequeueOutputBuffer(info, 10_000)
                if (idx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (eos) continue else break
                }
                if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val fmt = enc.outputFormat
                    val m = muxer ?: return 0
                    if (isVideo) videoTrackIdx = m.addTrack(fmt) else audioTrackIdx = m.addTrack(fmt)
                    if (videoTrackIdx >= 0 && audioTrackIdx >= 0 && !muxerStarted) {
                        m.start(); muxerStarted = true
                        Log.i(TAG, "muxer started")
                    }
                    continue
                }
                if (idx < 0) break
                val buf = enc.getOutputBuffer(idx) ?: run { enc.releaseOutputBuffer(idx, false); continue }
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    enc.releaseOutputBuffer(idx, false); continue
                }
                if (muxerStarted && info.size > 0) {
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    try { muxer?.writeSampleData(
                        if (isVideo) videoTrackIdx else audioTrackIdx, buf, info) } catch (_: Throwable) {}
                }
                enc.releaseOutputBuffer(idx, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
        } catch (t: Throwable) { Log.e(TAG, "drainEncoder error: ${t.message}") }
        return 0
    }

    private fun shortToBytes(s: ShortArray, n: Int): ByteArray {
        val out = ByteArray(n * 2)
        for (i in 0 until n) {
            out[i * 2] = (s[i].toInt() and 0xFF).toByte()
            out[i * 2 + 1] = (s[i].toInt() shr 8 and 0xFF).toByte()
        }
        return out
    }

    // ====================================================================
    //  边录边叫（需求 8.1）：播放预设叫声 + 录像同时录制该音频
    // ====================================================================
    fun playCall(asset: String, rate: Float) {
        // 解码 + 循环播放会阻塞，整体丢到 callExecutor，绝不卡主线程（防 ANR）。
        callExecutor.execute {
            val c = ctx ?: return@execute
            // 解码 wav → 单声道 16k PCM（短整型）
            val mono: ShortArray = decodeWavToMono(c, asset) ?: run {
                Log.e(TAG, "playCall: wav decode failed $asset"); return@execute
            }
            // 按 rate 线性重采样 → 播放 PCM（扬声器 + 混入录音）
            val resampled = resample(mono, rate)
            callShort = resampled; callLen = resampled.size; callPos = 0; callActive = true
            try {
                callTrack?.stop(); callTrack?.release(); callTrack = null
                val minBuf = maxOf(resampled.size * 2, 8192)
                callTrack = AudioTrack(AudioManager.STREAM_MUSIC, AUDIO_SAMPLE_RATE,
                    AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    minBuf, AudioTrack.MODE_STREAM)
                callTrack?.play()
                // 用本地 pos 到末尾归零实现循环（MODE_STREAM 不支持 setLoopPoints）
                var pos = 0
                val chunk = ShortArray(2048)
                while (callActive) {
                    val remaining = resampled.size - pos
                    if (remaining <= 0) { pos = 0; continue }
                    val take = minOf(chunk.size, remaining)
                    System.arraycopy(resampled, pos, chunk, 0, take)
                    callTrack?.write(chunk, 0, take)
                    pos += take
                }
            } catch (t: Throwable) {
                Log.e(TAG, "call playback failed: ${t.message}")
            } finally {
                // 同一线程里停止并释放，避免跨线程访问 AudioTrack
                try { callTrack?.stop() } catch (_: Throwable) {}
                try { callTrack?.release() } catch (_: Throwable) {}
                callTrack = null
            }
        }
    }

    fun stopCall() {
        // 仅翻转标志；真正 stop/release 在 callExecutor 播放循环的 finally 里做，
        // 保证与 AudioTrack 的 write 在同一线程，避免跨线程访问。
        callActive = false
    }

    /** 解码 Flutter 资源 wav 为 16k 单声道短整型数组（失败返回 null） */
    private fun decodeWavToMono(c: Context, asset: String): ShortArray? {
        return try {
            var ins = openFlutterAsset(c, asset)
            if (ins == null) return null
            val bytes = ins.readBytes()
            // 解析 44 字节头（PCM16）
            val numCh = (bytes[22].toInt() and 0xFF) or ((bytes[23].toInt() and 0xFF) shl 8)
            val sr = (bytes[24].toInt() and 0xFF) or ((bytes[25].toInt() and 0xFF) shl 8) or
                ((bytes[26].toInt() and 0xFF) shl 16) or ((bytes[27].toInt() and 0xFF) shl 24)
            val bits = (bytes[34].toInt() and 0xFF) or ((bytes[35].toInt() and 0xFF) shl 8)
            if (bits != 16) return null
            val dataLen = bytes.size - 44
            val totalSamples = dataLen / 2
            val interleaved = ShortArray(totalSamples)
            var p = 44
            for (i in 0 until totalSamples) {
                val v = (bytes[p].toInt() and 0xFF) or ((bytes[p + 1].toInt() and 0xFF) shl 8)
                interleaved[i] = if (v >= 0x8000) (v - 0x10000).toShort() else v.toShort()
                p += 2
            }
            // 转单声道 + 重采样到 16k
            val monoFull = if (numCh == 2) ShortArray(totalSamples / 2) { interleaved[it * 2] }
                          else interleaved
            if (sr == AUDIO_SAMPLE_RATE) monoFull
            else resample(monoFull, AUDIO_SAMPLE_RATE.toFloat() / sr)
        } catch (t: Throwable) {
            Log.e(TAG, "decodeWav failed: ${t.message}"); null
        }
    }

    private fun openFlutterAsset(c: Context, asset: String): java.io.InputStream? {
        for (key in listOf("flutter_assets/$asset", asset)) {
            try { return c.assets.open(key) } catch (_: Throwable) {}
        }
        return null
    }

    /** 线性重采样（ratio>1 变慢/降调，ratio<1 变快/升调） */
    private fun resample(src: ShortArray, ratio: Float): ShortArray {
        if (ratio <= 0f) return src
        val outLen = maxOf(1, (src.size / ratio).toInt())
        val out = ShortArray(outLen)
        for (i in 0 until outLen) {
            val pos = i.toFloat() * ratio
            val i0 = pos.toInt().coerceAtMost(src.size - 1)
            val i1 = (i0 + 1).coerceAtMost(src.size - 1)
            val frac = pos - i0
            val a = src[i0].toInt(); val b = src[i1].toInt()
            out[i] = (a + (b - a) * frac).toInt().coerceIn(-32768, 32767).toShort()
        }
        return out
    }

    // ====================================================================
    //  事件回传 Dart
    // ====================================================================
    private var lastSig = ""
    private fun emitIfChanged() {
        val sig = "$lastEmotion|$lastDetail|$lowLight|$hasPet|${if (postureRunning) 1 else 0}"
        if (sig == lastSig) return
        lastSig = sig
        val map = mapOf(
            "emotion" to lastEmotion,
            "detail" to lastDetail,
            "lowLight" to lowLight,
            "hasPet" to hasPet,
        )
        mainHandler.post { eventChannel?.invokeMethod("onCapture", map) }
    }
    private fun emitRecordState(on: Boolean) {
        mainHandler.post { eventChannel?.invokeMethod("onRecordState", on) }
    }

    // ====================================================================
    //  关闭
    // ====================================================================
    fun close() {
        stopPosture()
        stopCall()
        if (recording) stopRecord()
        try { captureSession?.close() } catch (_: Throwable) {}
        try { cameraDevice?.close() } catch (_: Throwable) {}
        captureSession = null; cameraDevice = null
        try { imageReader?.close() } catch (_: Throwable) {}
        imageReader = null
        previewSurface = null
    }
}

/** 相机预览视图：SurfaceView，Surface 就绪即交给 CameraRecorder 画预览 */
class CameraPreviewView(context: android.content.Context) :
    android.view.SurfaceView(context) {
    init { holder.addCallback(object : android.view.SurfaceHolder.Callback {
        override fun surfaceCreated(h: android.view.SurfaceHolder) {
            CameraRecorder.attachPreview(h.surface)
        }
        override fun surfaceChanged(h: android.view.SurfaceHolder, f: Int, w: Int, he: Int) {}
        override fun surfaceDestroyed(h: android.view.SurfaceHolder) {
            CameraRecorder.detachPreview(this@CameraPreviewView)
        }
    }) }
}

/** Flutter PlatformViewFactory（viewType = 'meowwoof/camera_preview'） */
class CameraPreviewFactory : PlatformViewFactory(StandardMessageCodec()) {
    override fun create(context: android.content.Context, viewId: Int, args: Any?): PlatformView {
        val view = CameraPreviewView(context)
        return object : PlatformView {
            override fun getView(): android.view.View = view
            override fun dispose() {
                view.holder.removeCallback(view)
                CameraRecorder.detachPreview(view)
            }
        }
    }
}
