package com.meowwoof.translator.pose

import android.util.Log

/**
 * 多源情绪融合（需求 5）：音频情绪 × 体态情绪 → 综合结论文案。
 *
 * 规则表（与需求一一对应，写进代码逻辑）：
 * | 音频结果      | 体态结果            | 综合结论文案              |
 * |-------------|-------------------|-------------------------|
 * | 痛悲惨叫      | 夹尾/耳后压/蜷缩     | 高度应激，留意宠物疼痛不适   |
 * | 低吼/哈气     | 炸毛警戒/压低趴卧     | 宠物愤怒，不要靠近         |
 * | 撒娇喵呜      | 舒展放松            | 放松愉悦，想要互动         |
 * | 兴奋吠叫      | 舒展放松            | 狗狗开心，精力旺盛          |
 * | 平静呼噜      | 舒展放松            | 猫咪安稳舒适              |
 * | 委屈呜咽      | 夹尾/蜷缩/恐惧       | 宠物害怕不安              |
 *
 * 兜底：
 *  ① 音频与体态冲突 → "宠物情绪矛盾，建议多观察"
 *  ② 一方识别失败 → 只展示可用一方，不强行输出综合结论
 */
object EmotionFusion {

    private const val TAG = "EmotionFusion"

    const val AU_PAIN = "痛苦惨叫"
    const val AU_GROWL = "低吼/哈气"
    const val AU_COAX = "撒娇喵呜"
    const val AU_EXCITED = "兴奋吠叫"
    const val AU_PURR = "平静呼噜"
    const val AU_WHINE = "委屈呜咽"

    // 体态标签（与 PoseRules 严格一致）
    const val PO_TENSE = PoseRules.EM_TENSE        // 紧张（耳后压）
    const val PO_CURL = PoseRules.EM_CURL          // 不安（身体蜷缩）
    const val PO_FEAR = PoseRules.EM_FEAR          // 恐惧（夹尾）
    const val PO_ALERT = PoseRules.EM_ALERT        // 警觉（压低趴卧）
    const val PO_RELAXED = PoseRules.EM_RELAXED    // 放松（舒展）
    const val PO_PILERECT = PoseRules.EM_PILERECT  // 炸毛警戒

    const val CONFLICT_TEXT = "宠物情绪矛盾，建议多观察"

    data class FusionResult(
        val audioEmotion: String?,
        val poseEmotion: String?,
        val conclusion: String,
        val isSingleSource: Boolean,
    )

    fun mergePetEmotion(audioEmotion: String?, poseEmotion: String?): FusionResult {
        Log.i(TAG, "mergePetEmotion(audio=$audioEmotion, pose=$poseEmotion)")
        if (audioEmotion == null && poseEmotion == null) {
            return FusionResult(null, null, "两个通道都未识别到可用结果", true)
        }
        if (audioEmotion == null) {
            return FusionResult(null, poseEmotion, "体态情绪：$poseEmotion", true)
        }
        if (poseEmotion == null) {
            return FusionResult(audioEmotion, null, "叫声情绪：$audioEmotion", true)
        }

        // 精确匹配（优先）
        val table = mapOf(
            "$AU_PAIN|$PO_FEAR" to "高度应激，留意宠物疼痛不适",
            "$AU_PAIN|$PO_TENSE" to "高度应激，留意宠物疼痛不适",
            "$AU_PAIN|$PO_CURL" to "高度应激，留意宠物疼痛不适",
            "$AU_GROWL|$PO_PILERECT" to "宠物愤怒，不要靠近",
            "$AU_GROWL|$PO_ALERT" to "宠物愤怒，不要靠近",
            "$AU_GROWL|$PO_TENSE" to "宠物愤怒，不要靠近",
            "$AU_COAX|$PO_RELAXED" to "放松愉悦，想要互动",
            "$AU_EXCITED|$PO_RELAXED" to "狗狗开心，精力旺盛",
            "$AU_PURR|$PO_RELAXED" to "猫咪安稳舒适",
            "$AU_WHINE|$PO_FEAR" to "宠物害怕不安",
            "$AU_WHINE|$PO_CURL" to "宠物害怕不安",
        )
        table["$audioEmotion|$poseEmotion"]?.let {
            Log.i(TAG, "table hit -> $it")
            return FusionResult(audioEmotion, poseEmotion, it, false)
        }

        // 分组兜底匹配
        val poseGroup = when (poseEmotion) {
            PO_FEAR, PO_TENSE, PO_CURL -> "stress"      // 夹尾/耳后压/蜷缩
            PO_PILERECT, PO_ALERT -> "aggressive"       // 炸毛/压低趴卧
            PO_RELAXED -> "relaxed"
            else -> "unknown"
        }
        val audioGroup = when (audioEmotion) {
            AU_PAIN -> "pain"
            AU_GROWL -> "aggressive"
            AU_COAX, AU_PURR -> "positive"
            AU_EXCITED -> "excited"
            AU_WHINE -> "stress"
            else -> "unknown"
        }
        val grouped = mapOf(
            "pain|stress" to "高度应激，留意宠物疼痛不适",
            "aggressive|aggressive" to "宠物愤怒，不要靠近",
            "positive|relaxed" to "放松愉悦，想要互动",
            "excited|relaxed" to "狗狗开心，精力旺盛",
        )
        grouped["$audioGroup|$poseGroup"]?.let {
            Log.i(TAG, "group hit -> $it")
            return FusionResult(audioEmotion, poseEmotion, it, false)
        }

        Log.i(TAG, "conflict fallthrough -> ${CONFLICT_TEXT}")
        return FusionResult(audioEmotion, poseEmotion, CONFLICT_TEXT, false)
    }
}
