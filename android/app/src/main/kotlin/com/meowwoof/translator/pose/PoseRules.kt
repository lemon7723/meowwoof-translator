package com.meowwoof.translator.pose

import android.util.Log

/**
 * 体态 → 情绪 规则引擎（纯 if 逻辑，无模型参与）。
 *
 * 关键点索引表（COCO 17 点布局）集中在此，未来替换宠物姿态模型时只改本表：
 *   0 鼻  1 左眼  2 右眼  3 左耳  4 右耳  5 左肩  6 右肩
 *   7 左肘 8 右肘 9 左腕 10 右腕 11 左髋 12 右髋 13 左膝
 *   14 右膝 15 左踝 16 右踝
 *
 * 诚实边界（界面同步标注）：
 *  - 单帧静态图无法直接感知「快速摆动/缓慢摇尾」这类时间维度动作，
 *    「摇尾」以尾根相对髋部的上扬角度近似（上扬=放松，下垂/夹=恐惧）。
 *  - COCO 布局没有尾巴与耳朵外缘点，近似用「髋部高度差」与「头部朝向」
 *    几何特征替代耳/尾语义；表结构已按宠物模型（含尾根/尾尖/耳基点）预留。
 */
object PoseRules {

    private const val TAG = "PoseRules"

    /** 关键点语义索引表：宠物姿态模型接入时替换此表即可 */
    data class KptIndex(
        val nose: Int = 0,
        val eyeL: Int = 1, val eyeR: Int = 2,
        val earL: Int = 3, val earR: Int = 4,
        val shoulderL: Int = 5, val shoulderR: Int = 6,
        val hipL: Int = 11, val hipR: Int = 12,
        // 以下为宠物姿态模型预留（COCO 无此语义，默认指向肩/髋近似点）
        val tailBase: Int = 11, val tailTip: Int = 7,
        val earBaseL: Int = 3, val earBaseR: Int = 4,
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
     * 判定体态情绪。
     * @param species "cat"/"dog"（需求 4 的猫狗规则不同）
     * @param kpts 17×3 关键点（x,y,conf 归一化）
     * @param minKptConf 关键点置信阈值（需求 3：低于判失败）
     * @return 情绪结果；关键点整体不可用时返回 null（=体态识别失败）
     */
    fun judge(species: String, kpts: FloatArray, minKptConf: Float = 0.5f): EmotionOut? {
        try {
            fun pt(i: Int): Pair<Float, Float>? =
                if (kpts[i * 3 + 2] >= minKptConf) kpts[i * 3] to kpts[i * 3 + 1] else null

            val nose = pt(IDX.nose)
            val shoulderMid = mid(pt(IDX.shoulderL), pt(IDX.shoulderR)) ?: return null
            val hipMid = mid(pt(IDX.hipL), pt(IDX.hipR))
            val earL = pt(IDX.earL); val earR = pt(IDX.earR)
            val tailBase = pt(IDX.tailBase); val tailTip = pt(IDX.tailTip)

            if (nose == null && earL == null && earR == null) {
                Log.i(TAG, "head keypoints below conf -> treat as pose fail")
                return null
            }

            // —— 几何特征 ——
            // 身体朝向角：肩中-髋中连线与竖直方向的夹角（前倾判定用）
            var leanForward = false
            var tailUp = false
            var tailTucked = false
            if (hipMid != null) {
                val dx = shoulderMid.first - hipMid.first
                val dy = shoulderMid.second - hipMid.second   // y 向下为正
                // 前倾：肩部明显低于髋部（画面 y 越大越靠下）且横向投影长
                leanForward = dy > 0.08f && Math.abs(dx) > 0.05f
                // 尾巴（近似）：尾尖相对尾根上扬 = 放松；下垂/内收 = 恐惧
                if (tailTip != null && tailBase != null) {
                    val ty = tailTip.second - tailBase.second
                    tailUp = ty < -0.05f
                    tailTucked = ty > 0.06f
                }
            }

            // —— 猫规则（需求 4）——
            if (species == "cat") {
                // 耳朵向后压：耳点高于（y 小于）眼点且横向内收 → 近似「耳后压」
                val earsBack = earsPressedBack(nose, earL, earR)
                return when {
                    earsBack -> EmotionOut(EM_TENSE, "耳朵向后压（近似判定：头部姿态内收）")
                    tailTucked -> EmotionOut(EM_IRRITATED, "尾巴下垂内收（近似：快速摆动的静态替代特征）")
                    tailUp -> EmotionOut(EM_RELAXED, "尾巴高举")
                    else -> EmotionOut(EM_RELAXED, "体态舒展，未见防御特征")
                }
            }

            // —— 狗规则（需求 4）——
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

    /** 耳后压近似：耳点存在且位于眼点上方（y 更小）→ 头部后收姿态 */
    private fun earsPressedBack(
        nose: Pair<Float, Float>?, earL: Pair<Float, Float>?, earR: Pair<Float, Float>?
    ): Boolean {
        if (earL == null && earR == null) return false
        // COCO 无耳基/耳尖方向信息，用「耳点与鼻的相对高度差」近似
        val ref = nose ?: return false
        val e = earL ?: earR!!
        return (ref.second - e.second) < -0.02f
    }

    private fun mid(a: Pair<Float, Float>?, b: Pair<Float, Float>?): Pair<Float, Float>? =
        when {
            a != null && b != null -> ((a.first + b.first) / 2f) to ((a.second + b.second) / 2f)
            a != null -> a
            else -> b
        }
}
