package com.meowwoof.translator.pose

import android.util.Log

/**
 * 多源情绪融合（需求 5）：音频情绪 × 体态情绪 → 综合结论文案。
 *
 * 规则表（与需求一一对应，写进代码逻辑）：
 * | 音频结果      | 体态结果        | 综合结论文案                    |
 * |-------------|---------------|-------------------------------|
 * | 痛悲惨叫      | 夹尾/耳后压      | 高度应激，留意宠物疼痛不适         |
 * | 低吼/哈气     | 炸毛、身体前倾    | 宠物愤怒，不要靠近               |
 * | 撒娇喵呜      | 尾巴高举        | 放松愉悦，想要互动               |
 * | 兴奋吠叫      | 缓慢摇尾        | 狗狗开心，精力旺盛                |
 * | 平静呼噜      | 体态放松        | 猫咪安稳舒适                    |
 * | 委屈呜咽      | 夹尾低头         | 宠物害怕不安                    |
 *
 * 兜底：
 *  ① 音频与体态冲突 → "宠物情绪矛盾，建议多观察"
 *  ② 一方识别失败 → 只展示可用一方，不强行输出综合结论
 */
object EmotionFusion {

    private const val TAG = "EmotionFusion"

    /** 音频情绪标签（与现有意图场景映射，见 mapAudioEmotion） */
    const val AU_PAIN = "痛苦惨叫"
    const val AU_GROWL = "低吼/哈气"
    const val AU_COAX = "撒娇喵呜"
    const val AU_EXCITED = "兴奋吠叫"
    const val AU_PURR = "平静呼噜"
    const val AU_WHINE = "委屈呜咽"

    /** 体态情绪标签 */
    const val PO_TENSE = PoseRules.EM_TENSE        // 紧张（耳后压）
    const val PO_ANGRY = PoseRules.EM_ANGRY        // 愤怒（炸毛/前倾）
    const val PO_RELAXED = PoseRules.EM_RELAXED    // 放松（尾巴高举/体态放松）
    const val PO_HAPPY = PoseRules.EM_HAPPY        // 放松开心（缓慢摇尾）
    const val PO_FEAR = PoseRules.EM_FEAR          // 恐惧（夹尾）
    const val PO_WARN = PoseRules.EM_WARN          // 警告（身体前倾）
    const val PO_IRRITATED = PoseRules.EM_IRRITATED // 烦躁

    /** 融合失败/冲突的文案 */
    const val CONFLICT_TEXT = "宠物情绪矛盾，建议多观察"

    data class FusionResult(
        val audioEmotion: String?,   // 可用方展示；null=该方失败
        val poseEmotion: String?,
        val conclusion: String,      // 综合解读（或单方结果/矛盾提示）
        val isSingleSource: Boolean, // true=只有一方可用（不强行综合）
    )

    /**
     * 需求入口函数：mergePetEmotion(audioEmotion, poseEmotion)
     * @param audioEmotion 6 类音频标签之一；null=音频情绪不可用
     * @param poseEmotion  体态标签；null=体态识别失败
     */
    fun mergePetEmotion(audioEmotion: String?, poseEmotion: String?): FusionResult {
        Log.i(TAG, "mergePetEmotion(audio=$audioEmotion, pose=$poseEmotion)")
        // 兜底②：单方失败 → 只展示可用一方
        if (audioEmotion == null && poseEmotion == null) {
            return FusionResult(null, null, "两个通道都未识别到可用结果", true)
        }
        if (audioEmotion == null) {
            return FusionResult(null, poseEmotion, "体态情绪：$poseEmotion", true)
        }
        if (poseEmotion == null) {
            return FusionResult(audioEmotion, null, "叫声情绪：$audioEmotion", true)
        }

        // 规则表精确匹配
        val table = mapOf(
            "$AU_PAIN|$PO_FEAR" to "高度应激，留意宠物疼痛不适",
            "$AU_PAIN|$PO_TENSE" to "高度应激，留意宠物疼痛不适",
            "$AU_GROWL|$PO_ANGRY" to "宠物愤怒，不要靠近",
            "$AU_GROWL|$PO_WARN" to "宠物愤怒，不要靠近",
            "$AU_COAX|$PO_RELAXED" to "放松愉悦，想要互动",
            "$AU_EXCITED|$PO_HAPPY" to "狗狗开心，精力旺盛",
            "$AU_PURR|$PO_RELAXED" to "猫咪安稳舒适",
            "$AU_WHINE|$PO_FEAR" to "宠物害怕不安",
        )
        table["$audioEmotion|$poseEmotion"]?.let {
            Log.i(TAG, "table hit -> $it")
            return FusionResult(audioEmotion, poseEmotion, it, false)
        }

        // 需求表的「夹尾/耳后压」「炸毛、身体前倾」「夹尾低头」为多标签组合
        val poseGroup = when (poseEmotion) {
            PO_FEAR, PO_TENSE -> "fearlike"      // 夹尾/耳后压/低头
            PO_ANGRY, PO_WARN, PO_IRRITATED -> "aggressive" // 炸毛/前倾
            PO_RELAXED, PO_HAPPY -> "relaxed"    // 高举/摇尾/放松
            else -> "unknown"
        }
        val audioGroup = when (audioEmotion) {
            AU_PAIN -> "pain"
            AU_GROWL -> "aggressive"
            AU_COAX, AU_PURR -> "positive"
            AU_EXCITED -> "excited"
            AU_WHINE -> "fearlike"
            else -> "unknown"
        }
        val grouped = mapOf(
            "pain|fearlike" to "高度应激，留意宠物疼痛不适",
            "aggressive|aggressive" to "宠物愤怒，不要靠近",
            "positive|relaxed" to "放松愉悦，想要互动",
            "excited|relaxed" to "狗狗开心，精力旺盛",
            "positive|relaxed2" to "猫咪安稳舒适",
            "fearlike|fearlike" to "宠物害怕不安",
        )
        grouped["$audioGroup|$poseGroup"]?.let {
            Log.i(TAG, "group hit -> $it")
            return FusionResult(audioEmotion, poseEmotion, it, false)
        }

        // 兜底①：冲突 → 情绪矛盾
        Log.i(TAG, "conflict fallthrough -> ${CONFLICT_TEXT}")
        return FusionResult(audioEmotion, poseEmotion, CONFLICT_TEXT, false)
    }
}
