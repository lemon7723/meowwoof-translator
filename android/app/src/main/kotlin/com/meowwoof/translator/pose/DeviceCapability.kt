package com.meowwoof.translator.pose

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.util.Log

/**
 * 设备性能分级（需求 6，原生侧权威判定）。
 *
 * 分三档（与 App 内 Device Guide 文案一致）：
 *  - recommended：A14+/骁龙888+/天玑8000+/Exynos2100+/Kirin9000+/Tensor，RAM≥8GB
 *  - minimum    ：骁龙845/855/865/870、天玑7000 同级，可运行但会掉帧/发热
 *  - legacy     ：低于上述（如骁龙8xx更早/7xx/6xx、RAM<4GB），默认关闭体态
 *
 * Android：读 Build.SOC_MODEL / BOARD / HARDWARE / MODEL + ActivityManager 内存。
 * iOS    ：无原生时由 Dart 端 device_info_plus 兜底；若后续补 iOS target，
 *          在 else 分支用 sysctl "hw.machine" 读 machine 字符串再分级。
 *
 * ⚠️ 不同厂商 Build.SOC_MODEL 命名差异大（如高通 SM8xxx、联发科 MTxxxx、海思 Kirin），
 *   真机实测后如有漏判，集中在本文件的匹配表里微调即可。
 */
object DeviceCapability {

    private const val TAG = "DeviceCap"

    enum class Tier { RECOMMENDED, MINIMUM, LEGACY, UNKNOWN }

    data class Result(val tier: Tier, val chip: String, val ramMb: Int)

    fun detect(ctx: Context): Map<String, Any?> {
        val r = evaluate(ctx)
        Log.i(TAG, "tier=${r.tier} chip=${r.chip} ramMb=${r.ramMb}")
        return mapOf(
            "tier" to when (r.tier) {
                Tier.RECOMMENDED -> "recommended"
                Tier.MINIMUM -> "minimum"
                Tier.LEGACY -> "legacy"
                else -> "unknown"
            },
            "chip" to r.chip,
            "ramMb" to r.ramMb,
        )
    }

    private fun evaluate(ctx: Context): Result {
        val soc = "${Build.SOC_MODEL} ${Build.BOARD} ${Build.HARDWARE} ${Build.MODEL}"
            .lowercase()
        val chipLabel = if (Build.SOC_MODEL.isNotBlank()) Build.SOC_MODEL else Build.BOARD
        val ramMb = runCatching {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            (mi.totalMem / (1024 * 1024)).toInt()
        }.getOrDefault(0)

        val tier = classify(soc, ramMb)
        return Result(tier, chipLabel, ramMb)
    }

    private fun classify(soc: String, ramMb: Int): Tier {
        // 推荐档
        if (soc.contains(Regex(
            "sm8350|sm8450|sm8475|sm8550|sm8580|sm8650|sm8750|" +   // 骁龙 888 / 8Gen1/+/2/3/4
            "sd 8|snapdragon 8|" +
            "mt6983|mt6985|mt6990|mt6989|dimensity 8|dimensity 9|" + // 天玑 8000/9000 系
            "exynos 21|exynos 22|exynos 2200|" +
            "kirin 9|" +                                            // 麒麟 9000 系
            "tensor"))) {
            return Tier.RECOMMENDED
        }
        // 最低兼容档（可运行，可能掉帧/发热）
        if (soc.contains(Regex(
            "sm8150|sm8250|sm7325|sm7375|sm7450|sm7480|" +          // 855/865/870/7Gen 系
            "sd 855|sd 865|sd 870|snapdragon 855|snapdragon 865|" +
            "mt6885|mt689|mt687|mt685|mt683|dimensity 7|dimensity 6|" +
            "exynos 13|exynos 14|exynos 1080|exynos 990|" +
            "kirin 8"))) {
            return Tier.MINIMUM
        }
        // 老旧档（低于 845 / 天玑7000 同级以下，或内存过低）
        if (soc.contains(Regex(
            "sm8150|sm81|sm71|sm61|sm62|" +                         // 845 之前 / 7xx / 6xx
            "sd 8[0-4]|sd 7|sd 6|snapdragon 8[0-4]|snapdragon 7|snapdragon 6|" +
            "mt67|mt68[0-2]|dimensity 5|dimensity 4|" +
            "exynos 9|exynos 10|exynos 850|" +
            "kirin 7|kirin 6"))) {
            return Tier.LEGACY
        }
        // 型号不明：内存 8GB+ 保守给 minimum，4GB 以下给 legacy，其余 unknown
        return when {
            ramMb >= 8 * 1024 -> Tier.MINIMUM
            ramMb > 0 && ramMb < 4 * 1024 -> Tier.LEGACY
            else -> Tier.UNKNOWN
        }
    }
}
