/// 多平台一键分享（v1.6.0，录像导出完成页）
///
/// 逻辑（需求 9）：
///  1. 检测本机是否安装对应 App；未安装按钮置灰，提示 "App not installed."
///  2. TikTok/Instagram/X/Facebook：唤起对应 App，把导出 MP4 送入发布草稿，
///     用户手动点击发布（与开发者账号完全隔离）。
///  3. YouTube：无法直接传入视频草稿，打开 App 并提示 "Please upload manually".
///  4. System Share：唤起原生系统分享面板（share_plus），可分享到任意支持的 App。
///
/// Android 端"检测安装 + 唤起"走原生（PackageManager / 隐式 Intent），
/// 保证只在确实安装时点亮按钮；System Share 走 share_plus。
library;

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

enum SocialApp { tiktok, instagram, x, facebook, youtube }

extension SocialAppMeta on SocialApp {
  String get label {
    switch (this) {
      case SocialApp.tiktok:
        return 'Share to TikTok';
      case SocialApp.instagram:
        return 'Share to Instagram';
      case SocialApp.x:
        return 'Share to X';
      case SocialApp.facebook:
        return 'Share to Facebook';
      case SocialApp.youtube:
        return 'Share to YouTube';
    }
  }

  /// 对应 App 的包名/URL scheme（原生检测与唤起用）
  String get package {
    switch (this) {
      case SocialApp.tiktok:
        return 'com.ss.android.ugc.trill'; // 国际版 TikTok
      case SocialApp.instagram:
        return 'com.instagram.android';
      case SocialApp.x:
        return 'com.twitter.android';
      case SocialApp.facebook:
        return 'com.facebook.katana';
      case SocialApp.youtube:
        return 'com.google.android.youtube';
    }
  }
}

class ShareService {
  static const MethodChannel _ch = MethodChannel('meowwoof/share');

  /// 批量检测本机是否安装这些社交 App。返回 {app: bool}。
  static Future<Map<SocialApp, bool>> checkInstalled(List<SocialApp> apps) async {
    final keys = apps.map((e) => e.name).toList();
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>(
          'checkInstalled', {'packages': apps.map((e) => e.package).toList()});
      final map = <SocialApp, bool>{};
      for (final a in apps) {
        map[a] = (r?[a.package] as bool?) ?? false;
      }
      return map;
    } on PlatformException catch (_) {
      // 原生不可用时全部视为未安装（按钮置灰，符合需求 2.1）
      return {for (final a in apps) a: false};
    }
  }

  /// 唤起对应社交 App 的发布草稿（传入本地 MP4 路径）。
  /// 返回 null 表示成功唤起；非空为错误/提示文案。
  static Future<String?> shareTo(SocialApp app, String filePath) async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('shareTo', {
        'package': app.package,
        'path': filePath,
      });
      return r?['message'] as String?;
    } on PlatformException catch (e) {
      return e.message ?? '唤起失败';
    }
  }

  /// 系统分享兜底：唤起原生分享面板，可分享到任意支持的 App。
  static Future<void> systemShare(String filePath, {String? subject}) async {
    final file = XFile(filePath);
    await Share.shareXFiles([file], subject: subject ?? 'Pet Mood Capture');
  }
}
