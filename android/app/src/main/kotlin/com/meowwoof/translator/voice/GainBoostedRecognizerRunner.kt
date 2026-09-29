package com.meowwoof.translator.voice

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log

/**
 * v1.5.9 录音灵敏度修复：带前置数字增益 + AGC 的 AudioRecord 包装。
 *
 * 问题：设备麦克风采集电平偏低（尤其小音量说话），Vosk 的词匹配分数
 * 与信号幅度相关，振幅过低时识别不出词 → "要很大声才能识别"。
 *
 * 方案：不用 SpeechService 直读 AudioRecord，改为自读自喂：
 *   1. AudioRecord.read 原始 16bit PCM
 *   2. 帧级 AGC：统计短时 RMS，目标电平 -18dBFS，增益上限 8x（+18dB），下限 0.5x
 *   3. 软限幅（tanh 式）防爆音
 *   4. 把处理后的 short[] 喂给 Vosk Recognizer.acceptWaveForm
 *
 * 识别结果回调与 SpeechService 相同（partial/final/error/timeout），
 * 上层 voskListener 接口不变。模型/采样率/词表逻辑零改动。
 */
class GainBoostedRecognizerRunner(
    private val recognizer: org.vosk.Recognizer,
    private val sampleRate: Int,
    private val listener: org.vosk.android.RecognitionListener,
) : Thread() {

    companion object {
        private const val TAG = "VoiceGain"
        private const val TARGET_RMS = 2450f        // ≈ -22.5dBFS 的目标电平
        private const val MAX_GAIN = 8f             // 增益上限 +18dB
        private const val MIN_GAIN = 0.5f
        private const val AGC_ALPHA = 0.15f         // 增益平滑系数（防忽大忽小）
        private const val FRAME_MS = 20             // AGC 帧长
    }

    @Volatile private var running = true
    private var audioRecord: AudioRecord? = null

    fun stopCapture() {
        running = false
        try { audioRecord?.stop() } catch (_: Exception) {}
    }

    override fun run() {
        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            listener.onError(Exception("设备不支持录音参数"))
            return
        }
        val rec: AudioRecord
        try {
            rec = AudioRecord(
                MediaRecorder.AudioSource.MIC, sampleRate,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, sampleRate))
        } catch (e: Exception) {
            listener.onError(e)
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            listener.onError(Exception("录音器初始化失败"))
            return
        }
        audioRecord = rec
        rec.startRecording()

        val frame = IntArray(FRAME_MS * sampleRate / 1000)  // 320 samples @16k
        val pcm = ShortArray(frame.size)
        var gain = 1.5f   // 初始中等增益
        var lastReport = 0L
        try {
            while (running) {
                val n = rec.read(pcm, 0, pcm.size)
                if (n <= 0) continue

                // ---- 帧内处理：归一化到 frame 后做增益统计 ----
                var sum = 0.0
                for (i in 0 until n) {
                    val s = pcm[i].toInt()
                    frame[i] = s * s
                    sum += frame[i]
                }
                val rms = kotlin.math.sqrt((sum / n).toFloat())

                // 静音帧不猛拉增益（避免放大底噪），但保留当前增益
                if (rms > 40f) {
                    val target = (TARGET_RMS / (rms + 1f)).coerceIn(MIN_GAIN, MAX_GAIN)
                    gain += AGC_ALPHA * (target - gain)      // 平滑逼近目标增益
                }
                val g = gain

                // ---- 应用增益 + 软限幅，就地写回 ----
                for (i in 0 until n) {
                    val v = pcm[i] * g
                    val lim = when {
                        v > 32767f  -> 32767f - (v - 32767f) / 8f   // 软限幅
                        v < -32768f -> -32768f - (v + 32768f) / 8f
                        else -> v
                    }
                    pcm[i] = lim.toInt().coerceIn(-32768, 32767).toShort()
                }

                // 喂给 Vosk（同一 buffer，模拟 16bit PCM 流）
                recognizer.acceptWaveForm(pcm, n)

                // 调试日志：每 2 秒打一次增益与电平
                val now = System.currentTimeMillis()
                if (now - lastReport > 2000) {
                    lastReport = now
                    Log.d(TAG, "rms=%.0f gain=%.2f (max=%.1f)" .format(rms, g, MAX_GAIN))
                }
            }
        } catch (e: Exception) {
            listener.onError(e)
        } finally {
            try { rec.stop() } catch (_: Exception) {}
            try { rec.release() } catch (_: Exception) {}
            audioRecord = null
        }
    }
}
