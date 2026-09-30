package com.meowwoof.translator.pose

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File

/**
 * 多平台一键分享（需求 9，原生侧）。
 *
 *  - checkInstalled(packages)：用 PackageManager 判断是否安装对应 App。
 *  - shareTo(package, path)：把本地 MP4 通过 ACTION_SEND 送入对应 App 的发布草稿
 *    （setPackage 锁定目标 App，用户手动点发布；与开发者账号完全隔离）。
 *  - YouTube：无法直接传入视频草稿 → 打开 App 主界面，返回提示文案
 *    "Please upload video manually inside YouTube".
 *
 * ⚠️ 分享视频需要 FileProvider 生成 content:// URI（Android 7+ 禁止 file:// 跨应用）。
 *    已在 AndroidManifest.xml 注册 ${applicationId}.fileprovider 并在
 *    res/xml/file_paths.xml 开放 cache/视频目录（见清单改动）。
 */
object ShareManager {

    private const val TAG = "ShareMgr"

    /** 检测本机是否安装这些包名 */
    fun checkInstalled(ctx: Context, packages: List<String>): Map<String, Boolean> {
        val pm = ctx.packageManager
        val out = HashMap<String, Boolean>()
        for (p in packages) {
            out[p] = try {
                pm.getPackageInfo(p, 0) != null
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
        return out
    }

    /**
     * 唤起对应 App 的发布草稿。返回 null=成功唤起；非空=提示/错误文案。
     */
    fun shareTo(ctx: Context, pkg: String, path: String): Map<String, Any?> {
        val file = File(path)
        if (!file.exists()) return mapOf("message" to "视频文件不存在")
        val youtube = (pkg == "com.google.android.youtube")
        return try {
            val uri = FileProvider.getUriForFile(
                ctx, "${ctx.packageName}.fileprovider", file)
            if (youtube) {
                // YouTube 无法直接传入草稿：仅打开 App，提示手动上传
                val launch = ctx.packageManager.getLaunchIntentForPackage(pkg)
                if (launch == null) return mapOf("message" to "App not installed")
                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                ctx.startActivity(launch)
                mapOf("message" to "Please upload video manually inside YouTube")
            } else {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "video/mp4"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    setPackage(pkg)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.startActivity(send)
                mapOf("message" to null)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "shareTo failed: ${t.message}")
            mapOf("message" to (t.message ?: "唤起失败"))
        }
    }
}
