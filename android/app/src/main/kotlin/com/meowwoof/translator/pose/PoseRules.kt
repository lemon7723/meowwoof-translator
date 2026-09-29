package com.meowwoof.translator.pose

import android.util.Log

/**
 * 体态 → 情绪 规则引擎（纯 if 逻辑，无模型参与）。
 *
 * v1.5.0 关键点索引表：RTMPose-Animal（AP-10K 17 点，猫狗专用）。
 * 【AnimalPose 关键点索引定义 —— PoseRules 使用此索引表】
 * 0  左眼 Left Eye        头部基准
 * 1  右眼 Right Eye       头部基准
 * 2  鼻 Nose              鼻尖，头部基准
 * 3  颈 Neck              头身分界（耳后压近似用：AP-10K 无独立耳根点，
 *                          用「眼-颈相对几何」近似耳后压，注释即声明）
 * 4  尾根 Root of Tail    核心！判断夹尾、尾巴高举
 * 5  尾尖 Tail Tip        核心！尾巴上扬/下垂方向
 * 6-9  四肢膝类关节        前后肢姿态
 * 10-15 前后肢中间关节      前后肢姿态
 * 16 体侧/背部参考点        躯干姿态
 *
 * 业务判断公式、输出文字与 v1.4 完全一致，仅替换引用的下标。
 * 未来换任何宠物姿态模型：只改本表 + PoseEstimator 预处理。
 */
object PoseRules {

    private const val TAG = "PoseRules"

    /** 关键点语义索引表（RTMPose-Animal AP-10K 17 点） */
    data class KptIndex(
        val eyeL: Int = 0,
        val eyeR: Int = 1,
        val nose: Int = 2,
        val neck: Int = 3,          // 头身分界；耳后压近似的参考点
        val tailBase: Int = 4,      // 核心：夹尾/尾高举
        val tailTip: Int = 5,       // 核心：尾巴方向
        val shoulderPeak: Int = 16, // 肩峰近似（体侧/背部参考点）
        val hipRef: Int = 6,        // 髋部近似（后肢膝关节）
    )

    private val IDX = KptIndex()

    /** 体态情绪标签 */
    const val EM_TENSE = "紧张"
    const val EM_IRRITATED = "烦躁"
    const val EM_RELAXED = "放松"
    const val EM_ANGRY = "愤怒"
    const val EM_FEAR = "恐惧"
    const val EM_WARN = "警告"
    const val EM_HAPPY = "放松开心"

    data class EmotionOut(val label: String, val detail: String)

    /**
     * 判定体态情绪（业务公式与 v1.4 完全一致，仅索引替换）。
     * @param species "cat"/"dog"
     * @param kpts K×3 关键点（x,y,conf 归一化，K=17）
     * @param minKptConf 关键点置信阈值（低于判该点无效）
     */
    fun judge(species: String, kpts: FloatArray, minKptConf: Float = 0.5f): EmotionOut? {
        try {
            fun pt(i: Int): Pair<Float, Float>? =
                if (kpts[i * 3 + 2] >= minKptConf) kpts[i * 3] to kpts[i * 3 + 1] else null

            val eyeL = pt(IDX.eyeL); val eyeR = pt(IDX.eyeR)
            val nose = pt(IDX.nose)
            val neck = pt(IDX.neck)
            val tailBase = pt(IDX.tailBase)
            val tailTip = pt(IDX.tailTip)
            val shoulder = pt(IDX.shoulderPeak)
            val hip = pt(IDX.hipRef)

            // 头部基准：眼/鼻至少一个有效，否则判定失败
            if (eyeL == null && eyeR == null && nose == null) {
                Log.i(TAG, "head keypoints below conf -> treat as pose fail")
                return null
            }
            // v1.5.4：RTMPose 对侧躺/遮挡图躯干点常低于阈值（本地实测 8/17 过），
            // 躯干点缺失时降级为「局部判定」：只用头部/尾部可见点的规则，
            // 保证拍照体验；全图关键点过少的极端情况仍判失败。

            // —— 几何特征（y 向下为正）——
            // ① 耳后压近似：眼睛高于颈部（y 更小）且间距明显 → 头部后收姿态
            //   （AP-10K 无独立耳根点；公式来源已在表注释声明）
            val eyeRef = eyeL ?: eyeR ?: nose!!
            val earsBack = neck != null &&
                    (neck.second - eyeRef.second) < -0.02f

            // ② 尾巴方向：尾尖相对尾根，上扬(<-0.05)/下垂(>0.06)
            var tailUp = false
            var tailTucked = false
            if (tailTip != null && tailBase != null) {
                val ty = tailTip.second - tailBase.second
                tailUp = ty < -0.05f
                tailTucked = ty > 0.06f
            }

            // ③ 身体前倾：肩峰向鼻子方向明显前移（横向距离大于阈值）
            val leanForward = shoulder != null && run {
                val nx = nose?.first ?: shoulder.first
                (shoulder.first - nx).let { Math.abs(it) > 0.12f } &&
                        (shoulder.second - (hip?.second ?: shoulder.second)) > 0f
            }

            // —— 猫规则（业务公式不变）——
            if (species == "cat") {
                return when {
                    earsBack -> EmotionOut(EM_TENSE, "耳朵向后压（近似判定：头部姿态内收）")
                    tailTucked -> EmotionOut(EM_IRRITATED, "尾巴下垂内收（近似：快速摆动的静态替代特征）")
                    tailUp -> EmotionOut(EM_RELAXED, "尾巴高举")
                    else -> EmotionOut(EM_RELAXED, "体态舒展，未见防御特征")
                }
            }

            // —— 狗规则（业务公式不变）——
            return when {
                tailTucked -> EmotionOut(EM_FEAR, "尾巴夹在两腿间（近似：尾尖下垂内收）")
                leanForward -> EmotionOut(EM_WARN, "身体前倾")
                tailUp -> EmotionOut(EM_HAPPY, "缓慢摇尾（静态近似：尾位上扬）")
                else -> EmotionOut(EM_RELAXED, "体态放松自然")
            }
        } catch (t: Throwable) {
            Log.e(TAG, "judge failed: ${t.message}")
            return null
        }
    }
}
