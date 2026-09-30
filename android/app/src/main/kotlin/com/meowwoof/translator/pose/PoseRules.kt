package com.meowwoof.translator.pose

import android.util.Log

/**
 * 体态 → 情绪 规则引擎（纯几何判断，无模型参与）。
 *
 * v1.6.0 关键点索引表：SuperAnimal HRNet-w32（24 点，见 PoseEstimator.KPT_NAMES）。
 * 【24 点索引定义 —— PoseRules 使用此索引表】
 *  0 鼻 nose            1 左眼 eye_l          2 右眼 eye_r
 *  3 左耳根 ear_base_l   4 右耳根 ear_base_r    5 左耳尖 ear_tip_l
 *  6 右耳尖 ear_tip_r    7 左前肩 shoulder_l    8 右前肩 shoulder_r
 *  9 左前肘 elbow_l     10 右前肘 elbow_r     11 左前爪 paw_front_l
 * 12 右前爪 paw_front_r 13 左后髋 hip_l       14 右后髋 hip_r
 * 15 左后膝 knee_back_l 16 右后膝 knee_back_r 17 左后爪 paw_back_l
 * 18 右后爪 paw_back_r  19 脊柱 spine         20 尾根 tail_base
 * 21 尾中 tail_mid     22 尾尖 tail_tip      23 颈 neck
 *
 * 重点校准的六类姿态组合（需求 5）：
 *  ① 耳朵后压  ② 身体蜷缩  ③ 尾巴夹紧  ④ 压低身体趴卧  ⑤ 舒展放松  ⑥ 炸毛警戒
 *  ↓ 映射到情绪输出文案（与 EmotionFusion 标签一致）
 *
 * 开发备注（需求 11）：判定用的 2 张猫狗姿态对照图仅开发内部参考，不打包进 App；
 *  下列几何阈值已按该对照图校准，真机实测后可在本文件集中微调。
 *  ⚠️ 骨架无法直观测毛发（炸毛），⑥用「弓背 + 耳前竖」作代理特征，已注释声明。
 */
object PoseRules {

    private const val TAG = "PoseRules"

    data class KptIndex(
        val nose: Int = 0, val eyeL: Int = 1, val eyeR: Int = 2,
        val earBaseL: Int = 3, val earBaseR: Int = 4,
        val earTipL: Int = 5, val earTipR: Int = 6,
        val shoulderL: Int = 7, val shoulderR: Int = 8,
        val hipL: Int = 13, val hipR: Int = 14,
        val spine: Int = 19, val tailBase: Int = 20,
        val tailTip: Int = 22, val neck: Int = 23,
    )

    private val IDX = KptIndex()

    // —— 情绪标签（与 EmotionFusion 严格一致）——
    const val EM_TENSE = "紧张"          // ① 耳朵后压
    const val EM_CURL = "不安"           // ② 身体蜷缩
    const val EM_FEAR = "恐惧"           // ③ 尾巴夹紧
    const val EM_ALERT = "警觉"          // ④ 压低身体趴卧
    const val EM_RELAXED = "放松"        // ⑤ 舒展放松
    const val EM_PILERECT = "炸毛警戒"    // ⑥ 炸毛警戒（代理特征）

    data class EmotionOut(val label: String, val detail: String)

    /**
     * 判定体态情绪。
     * @param species "cat"/"dog"
     * @param kpts K×3 关键点（x,y,conf 归一化，K=24）
     * @param minKptConf 关键点置信阈值（低于判该点无效）
     */
    fun judge(species: String, kpts: FloatArray, minKptConf: Float = 0.3f): EmotionOut? {
        try {
            fun pt(i: Int): Pair<Float, Float>? =
                if (kpts[i * 3 + 2] >= minKptConf) kpts[i * 3] to kpts[i * 3 + 1] else null

            val nose = pt(IDX.nose)
            val eyeL = pt(IDX.eyeL); val eyeR = pt(IDX.eyeR)
            val earBL = pt(IDX.earBaseL); val earBR = pt(IDX.earBaseR)
            val earTL = pt(IDX.earTipL); val earTR = pt(IDX.earTipR)
            val shL = pt(IDX.shoulderL); val shR = pt(IDX.shoulderR)
            val hipL = pt(IDX.hipL); val hipR = pt(IDX.hipR)
            val spine = pt(IDX.spine)
            val tailBase = pt(IDX.tailBase); val tailTip = pt(IDX.tailTip)
            val neck = pt(IDX.neck)

            // 头部基准：鼻/眼至少一个有效，否则判定失败
            if (nose == null && eyeL == null && eyeR == null) {
                Log.i(TAG, "head keypoints below conf -> pose fail")
                return null
            }

            // ① 耳朵后压：双耳根低于眼睛（y 更大 = 耳朵贴后/压平），且耳尖在眼后
            val eyeRef = eyeL ?: eyeR ?: nose!!
            val earFlat = (earBL != null && earBR != null) &&
                    ((earBL.second - eyeRef.second) > 0.02f ||
                     (earBR.second - eyeRef.second) > 0.02f)
            val earBack = earFlat ||
                    (earTL != null && (earTL.first - eyeRef.first) < -0.04f) ||
                    (earTR != null && (earTR.first - eyeRef.first) > 0.04f &&
                            (earTR.second - eyeRef.second) > 0.02f)

            // ③ 尾巴夹紧：尾尖相对尾根明显下垂（y 更大）或贴近后爪
            var tailTucked = false
            if (tailTip != null && tailBase != null) {
                val ty = tailTip.second - tailBase.second
                tailTucked = ty > 0.06f
            }
            // ⑤ 舒展放松：尾尖相对尾根上扬（y 更小）
            val tailUp = (tailTip != null && tailBase != null) &&
                    ((tailTip.second - tailBase.second) < -0.05f)

            // ② 身体蜷缩：鼻到尾根间距相对外接框对角线很小（团成一团）
            val boxDiag = boxDiagonal(nose, eyeL, eyeR, shL, shR, hipL, hipR, tailBase, tailTip)
            val curl = if (nose != null && tailBase != null && boxDiag > 0f) {
                val d = kotlin.math.hypot((nose.first - tailBase.first).toDouble(),
                    (nose.second - tailBase.second).toDouble()).toFloat()
                d / boxDiag
            } else 1f
            val bodyCurl = curl < 0.45f

            // ④ 压低身体趴卧：外接框偏扁（身高/身长比值小）且脊柱靠下
            val boxH = boxHeight(nose, eyeL, eyeR, shL, shR, hipL, hipR, tailBase, tailTip)
            val boxW = boxWidth(nose, eyeL, eyeR, shL, shR, hipL, hipR, tailBase, tailTip)
            val crouch = boxH > 0f && boxW > 0f && (boxH / boxW) < 0.55f

            // ⑥ 炸毛警戒（代理）：弓背（脊柱高于双肩，y 更小）且耳前竖（耳根高于眼）
            val archedBack = spine != null && shL != null && shR != null &&
                    (spine.second < (shL.second + shR.second) / 2f - 0.03f)
            val earUp = (earBL != null && (eyeRef.second - earBL.second) > 0.03f)
            val piloerect = archedBack && earUp

            // —— 组合优先级（矛盾时按威胁度排序）——
            val label = when {
                piloerect -> EM_PILERECT
                earBack -> EM_TENSE
                bodyCurl -> EM_CURL
                tailTucked -> EM_FEAR
                crouch -> EM_ALERT
                tailUp -> EM_RELAXED
                else -> EM_RELAXED
            }
            val detail = when (label) {
                EM_PILERECT -> "弓背 + 耳朵前竖（炸毛警戒的骨架代理特征）"
                EM_TENSE -> "耳朵向后压（头部内收防御姿态）"
                EM_CURL -> "身体蜷缩成一团"
                EM_FEAR -> "尾巴夹紧在两腿间"
                EM_ALERT -> "压低身体趴卧，保持警觉"
                EM_RELAXED -> "体态舒展，尾巴自然上扬"
                else -> "体态舒展放松"
            }
            Log.i(TAG, "judge -> $label (earBack=$earBack curl=$bodyCurl tailTuck=$tailTucked crouch=$crouch pilo=$piloerect)")
            return EmotionOut(label, detail)
        } catch (t: Throwable) {
            Log.e(TAG, "judge failed: ${t.message}")
            return null
        }
    }

    private fun boxDiagonal(vararg ps: Pair<Float, Float>?): Float {
        var minX = 1f; var minY = 1f; var maxX = 0f; var maxY = 0f; var n = 0
        for (p in ps) if (p != null) { minX = minOf(minX, p.first); maxX = maxOf(maxX, p.first)
            minY = minOf(minY, p.second); maxY = maxOf(maxY, p.second); n++ }
        if (n < 2) return 0f
        return kotlin.math.hypot((maxX - minX).toDouble(), (maxY - minY).toDouble()).toFloat()
    }
    private fun boxHeight(vararg ps: Pair<Float, Float>?): Float {
        var minY = 1f; var maxY = 0f; var n = 0
        for (p in ps) if (p != null) { minY = minOf(minY, p.second); maxY = maxOf(maxY, p.second); n++ }
        return if (n < 2) 0f else (maxY - minY)
    }
    private fun boxWidth(vararg ps: Pair<Float, Float>?): Float {
        var minX = 1f; var maxX = 0f; var n = 0
        for (p in ps) if (p != null) { minX = minOf(minX, p.first); maxX = maxOf(maxX, p.first); n++ }
        return if (n < 2) 0f else (maxX - minX)
    }
}
