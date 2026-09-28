package com.meowwoof.translator

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import org.vosk.android.StorageService
import java.io.File
import java.io.FileOutputStream
import java.util.Collections
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 毛语通 · Android 原生桥接（v1.0.0）
 *
 * 职责（全部离线，唯一权限 RECORD_AUDIO）：
 * 1. 离线中文语音识别：Vosk 小模型（assets/model-cn 由 CI 打包时下载）
 *    - StorageService.unpack 解包到应用私有目录
 *    - Recognizer 带词表语法（grammar），只识别毛语通意图词表，小模型识别更准
 *    - SpeechService 持续收音，partial/final 结果经 MethodChannel 回传 Dart
 * 2. 录宠物声音：AudioRecord 16kHz 单声道 PCM，停止后写 WAV 并做自相关音高分析
 * 3. 叫声播放：MediaPlayer 播放 assets/sounds 目录内的 wav（先拷到 cacheDir），
 *    用 PlaybackParams.speed 做音色匹配（整体变速变调，类似磁带转速）
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "meowwoof/voice"
        private const val BUILD_TAG = "v1.2.1"
        private const val SAMPLE_RATE = 16000
        private const val PERM_REQ = 2001
        private const val MAX_REC_SECONDS = 120
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val TAG = "MeowWoof"

    // ---- Vosk ----
    private var model: Model? = null
    private var speechService: SpeechService? = null
    private var channelRef: MethodChannel? = null

    // ---- 录音 ----
    private var audioRecord: AudioRecord? = null
    private var recThread: Thread? = null
    private val recBuffer: MutableList<Short> = Collections.synchronizedList(ArrayList())
    @Volatile private var recording = false

    // ---- 播放 ----
    private var player: MediaPlayer? = null

    // ---- 权限 ----
    private var pendingPermResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channelRef = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channelRef?.setMethodCallHandler { call, result ->
            when (call.method) {
                "buildVersion" -> result.success(BUILD_TAG)
                "hasMicPermission" -> result.success(hasMicPermission())
                "requestMicPermission" -> requestMicPermission(result)
                "initModel" -> initModel(result)
                "startListening" -> startListening(call.argument<String>("grammar"), result)
                "stopListening" -> stopListening(result)
                "startPetRecording" -> startPetRecording(result)
                "stopPetRecording" -> stopPetRecording(result)
                "playCall" -> playCall(
                    call.argument<String>("asset") ?: "",
                    (call.argument<Double>("rate") ?: 1.0).toFloat(),
                    call.argument<Int>("repeat") ?: 1,
                    result
                )
                "stopPlaying" -> {
                    stopPlaying()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasMicPermission(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestMicPermission(result: MethodChannel.Result) {
        if (hasMicPermission()) {
            result.success(true)
            return
        }
        pendingPermResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), PERM_REQ)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERM_REQ) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermResult?.let { r -> mainHandler.post { r.success(granted) } }
            pendingPermResult = null
        }
    }

    // ================= Vosk 模型 =================

    private var initResult: MethodChannel.Result? = null

    private fun initModel(result: MethodChannel.Result) {
        if (model != null) {
            result.success("ready")
            return
        }
        if (initResult != null) {
            result.error("BUSY", "模型正在初始化", null)
            return
        }
        initResult = result
        StorageService.unpack(
            this, "model-cn", "model",
            { m ->
                model = m
                initResult?.let { r -> mainHandler.post { r.success("ready") } }
                initResult = null
            },
            { e ->
                initResult?.let {
                    r -> mainHandler.post {
                        r.error("MODEL_FAIL",
                            "模型解包失败：${e.message}。请确认 APK 内含 assets/model-cn/", null)
                    }
                }
                initResult = null
            }
        )
    }

    // ================= 实时识别 =================

    private fun startListening(grammar: String?, result: MethodChannel.Result) {
        val m = model
        if (m == null) {
            result.error("NO_MODEL", "模型未初始化，请先 initModel", null)
            return
        }
        executor.execute {
            try {
                speechService?.stop()
                speechService = null
                val rec = if (grammar.isNullOrBlank()) {
                    Recognizer(m, SAMPLE_RATE.toFloat())
                } else {
                    Recognizer(m, SAMPLE_RATE.toFloat(), grammar)
                }
                val service = SpeechService(rec, SAMPLE_RATE.toFloat())
                service.startListening(voskListener)
                speechService = service
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                mainHandler.post { result.error("START_FAIL", e.message, null) }
            }
        }
    }

    private fun stopListening(result: MethodChannel.Result) {
        executor.execute {
            try {
                // stop() 结束收音并冲刷解码器，final 结果会回调 onFinalResult
                speechService?.stop()
                mainHandler.post { result.success(true) }
            } catch (e: Exception) {
                mainHandler.post { result.error("STOP_FAIL", e.message, null) }
            }
        }
    }

    private val voskListener = object : RecognitionListener {
        override fun onPartialResult(hypothesis: String?) {
            val json = hypothesis ?: return
            mainHandler.post { channelRef?.invokeMethod("onPartial", json) }
        }

        override fun onFinalResult(hypothesis: String?) {
            val json = hypothesis ?: return
            mainHandler.post { channelRef?.invokeMethod("onFinal", json) }
        }

        override fun onResult(hypothesis: String?) {
            // SpeechStreamService 用，SpeechService 场景忽略
        }

        override fun onError(e: Exception?) {
            mainHandler.post { channelRef?.invokeMethod("onError", e?.message ?: "识别出错") }
        }

        override fun onTimeout() {
            mainHandler.post { channelRef?.invokeMethod("onFinal", "{}") }
        }
    }

    // ================= 录宠物声音 =================

    private fun startPetRecording(result: MethodChannel.Result) {
        if (recording) {
            result.error("BUSY", "已在录音中", null)
            return
        }
        if (!hasMicPermission()) {
            result.error("NO_PERM", "缺少麦克风权限", null)
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBuf <= 0) {
            result.error("REC_FAIL", "设备不支持录音参数", null)
            return
        }
        val bufSize = maxOf(minBuf, SAMPLE_RATE) // ≥1 秒缓冲
        val rec: AudioRecord
        try {
            rec = AudioRecord(
                MediaRecorder.AudioSource.MIC, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, bufSize
            )
        } catch (e: Exception) {
            result.error("REC_FAIL", "创建录音器失败：${e.message}", null)
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            result.error("REC_FAIL", "录音器初始化失败", null)
            return
        }
        synchronized(recBuffer) { recBuffer.clear() }
        recording = true
        audioRecord = rec
        rec.startRecording()
        val maxSamples = SAMPLE_RATE * MAX_REC_SECONDS
        recThread = Thread {
            val chunk = ShortArray(2048)
            while (recording) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n > 0) {
                    synchronized(recBuffer) {
                        if (recBuffer.size < maxSamples) {
                            for (i in 0 until n) recBuffer.add(chunk[i])
                        }
                    }
                }
            }
        }.also { it.start() }
        result.success(true)
    }

    private fun stopPetRecording(result: MethodChannel.Result) {
        if (!recording) {
            result.error("NOT_RECORDING", "没有进行中的录音", null)
            return
        }
        recording = false
        val rec = audioRecord
        audioRecord = null
        try { rec?.stop() } catch (_: Exception) {}
        try { rec?.release() } catch (_: Exception) {}
        executor.execute {
            try {
                recThread?.join(2000)
                recThread = null
                val samples: ShortArray = synchronized(recBuffer) { recBuffer.toShortArray() }
                if (samples.size < SAMPLE_RATE / 4) {
                    mainHandler.post {
                        result.error("TOO_SHORT", "录音太短（不足 0.25 秒），再录一次吧", null)
                    }
                    return@execute
                }
                val file = File(filesDir, "pet_voice_${System.currentTimeMillis()}.wav")
                writeWav(file, samples, SAMPLE_RATE)
                val analysis = analyzePitch(samples, SAMPLE_RATE)
                val out = HashMap<String, Any>()
                out["path"] = file.absolutePath
                out["durationMs"] = samples.size * 1000L / SAMPLE_RATE
                out["f0"] = analysis.first
                out["voicedRatio"] = analysis.second
                mainHandler.post { result.success(out) }
            } catch (e: Exception) {
                mainHandler.post { result.error("ANALYZE_FAIL", e.message, null) }
            }
        }
    }

    /** 标准 44 字节头的 16-bit PCM WAV */
    private fun writeWav(file: File, samples: ShortArray, sampleRate: Int) {
        val dataLen = samples.size * 2
        FileOutputStream(file).use { out ->
            val header = ByteArray(44)
            fun putInt(off: Int, v: Int) {
                header[off] = (v and 0xff).toByte()
                header[off + 1] = ((v shr 8) and 0xff).toByte()
                header[off + 2] = ((v shr 16) and 0xff).toByte()
                header[off + 3] = ((v shr 24) and 0xff).toByte()
            }
            fun putShort(off: Int, v: Int) {
                header[off] = (v and 0xff).toByte()
                header[off + 1] = ((v shr 8) and 0xff).toByte()
            }
            header[0] = 'R'.code.toByte(); header[1] = 'I'.code.toByte()
            header[2] = 'F'.code.toByte(); header[3] = 'F'.code.toByte()
            putInt(4, 36 + dataLen)
            header[8] = 'W'.code.toByte(); header[9] = 'A'.code.toByte()
            header[10] = 'V'.code.toByte(); header[11] = 'E'.code.toByte()
            header[12] = 'f'.code.toByte(); header[13] = 'm'.code.toByte()
            header[14] = 't'.code.toByte(); header[15] = ' '.code.toByte()
            putInt(16, 16)                 // PCM chunk size
            putShort(20, 1)                // PCM
            putShort(22, 1)                // mono
            putInt(24, sampleRate)
            putInt(28, sampleRate * 2)     // byte rate
            putShort(32, 2)                // block align
            putShort(34, 16)               // bits
            header[36] = 'd'.code.toByte(); header[37] = 'a'.code.toByte()
            header[38] = 't'.code.toByte(); header[39] = 'a'.code.toByte()
            putInt(40, dataLen)
            out.write(header)
            val bytes = ByteArray(dataLen)
            for (i in samples.indices) {
                val v = samples[i].toInt()
                bytes[i * 2] = (v and 0xff).toByte()
                bytes[i * 2 + 1] = ((v shr 8) and 0xff).toByte()
            }
            out.write(bytes)
        }
    }

    /**
     * 自相关音高检测：分帧（1024 点 / 512 偏移），对能量足够的帧
     * 在 60~500Hz 范围找归一化自相关峰值，取全部有声帧的中位数。
     * 返回 (f0Hz, 有声帧比例)；无声返回 (0.0, 0.0)。
     */
    private fun analyzePitch(samples: ShortArray, sampleRate: Int): Pair<Double, Double> {
        val frame = 1024
        val hop = 512
        val minLag = sampleRate / 500   // 500Hz
        val maxLag = sampleRate / 60    // 60Hz
        val f0s = ArrayList<Double>()
        var frames = 0

        // 全局峰值用于静音阈值
        var peak = 1
        for (s in samples) { val a = abs(s.toInt()); if (a > peak) peak = a }
        val silence = peak * 0.08

        var i = 0
        while (i + frame <= samples.size) {
            frames++
            val x = DoubleArray(frame)
            var rms = 0.0
            for (j in 0 until frame) {
                val v = samples[i + j].toDouble()
                x[j] = v
                rms += v * v
            }
            rms = sqrt(rms / frame)
            if (rms < silence) { i += hop; continue }

            var r0 = 0.0
            for (j in 0 until frame) r0 += x[j] * x[j]
            if (r0 <= 0.0) { i += hop; continue }

            var bestLag = -1
            var bestVal = 0.0
            var lag = minLag
            while (lag <= maxLag && lag < frame) {
                var rl = 0.0
                for (j in 0 until frame - lag) rl += x[j] * x[j + lag]
                val norm = rl / r0
                if (norm > bestVal) { bestVal = norm; bestLag = lag }
                lag++
            }
            if (bestLag > 0 && bestVal > 0.55) {
                f0s.add(sampleRate.toDouble() / bestLag)
            }
            i += hop
        }
        if (f0s.isEmpty()) return Pair(0.0, 0.0)
        f0s.sort()
        val median = f0s[f0s.size / 2]
        return Pair(median, f0s.size.toDouble() / frames)
    }

    // ================= 叫声播放 =================

    /**
     * 打开 Flutter 资源。Dart 侧资源键是 "assets/sounds/xx.wav"，
     * 但在 APK 内实际位于 flutter_assets/ 前缀之下。
     * 先试标准前缀，再回退裸路径（兼容不同打包形态）。
     */
    private fun openFlutterAsset(asset: String): java.io.InputStream? {
        for (key in listOf("flutter_assets/$asset", asset)) {
            try {
                val s = assets.open(key)
                android.util.Log.d(TAG, "openFlutterAsset: $asset -> $key")
                return s
            } catch (_: Exception) {
            }
        }
        android.util.Log.e(TAG, "openFlutterAsset failed: $asset")
        return null
    }

    private fun stopPlaying() {
        try {
            player?.stop()
        } catch (_: Exception) {}
        try {
            player?.release()
        } catch (_: Exception) {}
        player = null
    }

    private fun playCall(assetOrPath: String, rate: Float, repeat: Int, result: MethodChannel.Result) {
        if (assetOrPath.isBlank()) {
            result.error("BAD_ARGS", "缺少叫声文件路径", null)
            return
        }
        executor.execute {
            try {
                stopPlaying()
                val f: File =
                    if (assetOrPath.startsWith("/")) {
                        // 绝对路径（宠物录音回放）直接用
                        File(assetOrPath)
                    } else {
                        // Flutter 资源不能直接给 MediaPlayer，先落到 cacheDir（幂等）
                        val target = File(cacheDir, assetOrPath.replace("/", "_"))
                        if (!target.exists() || target.length() == 0L) {
                            val input = openFlutterAsset(assetOrPath)
                            if (input == null) {
                                mainHandler.post {
                                    result.error(
                                        "PLAY_FAIL",
                                        "找不到叫声资源：$assetOrPath（APK 内资源缺失？）", null)
                                }
                                return@execute
                            }
                            input.use { ins -> FileOutputStream(target).use { ins.copyTo(it) } }
                        }
                        target
                    }
                if (!f.exists() || f.length() == 0L) {
                    mainHandler.post {
                        result.error("PLAY_FAIL", "音频文件不存在：${f.name}", null)
                    }
                    return@execute
                }
                val mp = MediaPlayer()
                mp.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                mp.setDataSource(f.absolutePath)
                mp.prepare()
                val dur = mp.duration
                if (Build.VERSION.SDK_INT >= 23) {
                    // 变速同时变调（重采样），用作音色匹配
                    mp.playbackParams = mp.playbackParams.setSpeed(rate)
                }
                // v1.2.1：短叫声连播（带间隙，模拟真实呼叫节奏）
                val totalRepeats = if (repeat > 1 && dur < 3000) repeat else 1
                val gapMs = 220L
                var done = 1
                mp.setOnCompletionListener { p ->
                    if (done < totalRepeats) {
                        done++
                        mainHandler.postDelayed({
                            try {
                                p.seekTo(0)
                                p.start()
                            } catch (_: Exception) {}
                        }, gapMs)
                    } else {
                        try { p.release() } catch (_: Exception) {}
                        if (player === p) player = null
                    }
                }
                player = mp
                mp.start()
                val totalMs = dur * totalRepeats + (gapMs * (totalRepeats - 1)).toInt()
                android.util.Log.d(TAG, "playCall OK: $assetOrPath dur=${dur}ms x$totalRepeats rate=$rate")
                mainHandler.post { result.success(mapOf("durationMs" to totalMs)) }
            } catch (e: Exception) {
                android.util.Log.e(TAG, "playCall failed: ${e.message}")
                mainHandler.post { result.error("PLAY_FAIL", "播放失败：${e.message}", null) }
            }
        }
    }

    override fun onDestroy() {
        recording = false
        try { audioRecord?.stop() } catch (_: Exception) {}
        try { audioRecord?.release() } catch (_: Exception) {}
        executor.execute { speechService?.stop() }
        stopPlaying()
        super.onDestroy()
    }
}
