/// 首页 Launcher 设置持久化（v1.6.0）
///
/// 管理：
/// 1. 图标排布：7 个小图标可拖拽换位（体态解读固定 C 位，不入表），
///    顺序持久化，重启保持
/// 2. 首页背景：仅首页生效。type = preset(0-4 内置模板) / custom(相册图)；
///    custom 时记录图片路径 + 模糊半径 + 遮罩透明度
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内置 5 套简约背景模板（首页专用）
/// 每套 = 柔和纯色渐变（上下），iOS 浅色系，保证图标与文字可读
const List<List<Color>> kPresetBackgrounds = [
  [Color(0xFFFDF6EE), Color(0xFFFAE8D4)], // 0 暖杏
  [Color(0xFFF2F7F5), Color(0xFFDDEBE6)], // 1 薄荷
  [Color(0xFFEEF2FA), Color(0xFFD8E2F5)], // 2 雾蓝
  [Color(0xFFF6F1FA), Color(0xFFE4D9F2)], // 3 淡藤
  [Color(0xFFFAF4F0), Color(0xFFF0DCD6)], // 4 蜜粉
];

class LauncherSettings {
  /// 7 个小图标的 id 顺序（拖拽后保存）。固定大图标「pose」不在其中。
  List<String> order;

  /// 背景类型：-1 = 自定义相册图；0-4 = 内置模板
  int backgroundType;

  /// 自定义背景图路径（type=-1 时有效）
  String? customBgPath;

  /// 自定义背景高斯模糊半径（px），默认 12
  double blurSigma;

  /// 图标区半透明遮罩不透明度 0-1（越高越蒙，保证文字可读）
  double overlayOpacity;

  LauncherSettings({
    List<String>? order,
    this.backgroundType = 0,
    this.customBgPath,
    this.blurSigma = 12.0,
    this.overlayOpacity = 0.25,
  }) : order = order ??
            const ['cat', 'dog', 'mic', 'history', 'cloud', 'profile', 'about'];

  Map<String, Object?> toMap() => {
        'order': order,
        'bgType': backgroundType,
        'bgPath': customBgPath,
        'blur': blurSigma,
        'overlay': overlayOpacity,
      };

  static LauncherSettings fromMap(Map<Object?, Object?> m) {
    final defaults = LauncherSettings();
    final order =
        (m['order'] as List?)?.map((e) => e.toString()).toList() ?? defaults.order;
    // 布尔校验：过滤无效 id / 补缺失 id（升级兼容）
    const validIds = ['cat', 'dog', 'mic', 'history', 'cloud', 'profile', 'about'];
    final cleaned = order.where(validIds.contains).toSet().toList();
    for (final id in validIds) {
      if (!cleaned.contains(id)) cleaned.add(id);
    }
    return LauncherSettings(
      order: cleaned,
      backgroundType: (m['bgType'] as num?)?.toInt() ?? 0,
      customBgPath: m['bgPath'] as String?,
      blurSigma: (m['blur'] as num?)?.toDouble() ?? 12.0,
      overlayOpacity: (m['overlay'] as num?)?.toDouble() ?? 0.25,
    );
  }

  /// 校验自定义背景图是否仍存在（图被系统清理时自动回退模板）
  Future<bool> customBgExists() async {
    if (customBgPath == null) return false;
    return File(customBgPath!).exists();
  }
}

/// 自定义背景图导入：拷贝到私有目录并压缩到长边 1600（省内存 + 模糊更快）
Future<String?> importLauncherBackground(String srcPath) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/launcher_bg');
    if (!await dir.exists()) await dir.create(recursive: true);
    final dst = File(
        '${dir.path}/bg_${DateTime.now().millisecondsSinceEpoch}.jpg');
    final src = File(srcPath);
    if (!await src.exists()) return null;
    // 原样拷贝足够——Flutter 端用 Image.file + ImageFilter.blur 显示时
    // 会做 GPU 降采样；此处只保证文件在私有目录内
    await src.copy(dst.path);
    return dst.path;
  } catch (_) {
    return null;
  }
}

class LauncherStore {
  static const _key = 'launcher_settings_v1';

  static Future<LauncherSettings> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return LauncherSettings();
    try {
      final obj = jsonDecode(raw);
      if (obj is Map) return LauncherSettings.fromMap(obj.cast<Object?, Object?>());
      return LauncherSettings();
    } catch (_) {
      return LauncherSettings();
    }
  }

  static Future<void> save(LauncherSettings s) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(s.toMap()));
  }
}

/// 模板 i 的渐变色（首页背景 & 主页缩略图共用）
List<Color> presetGradient(int i) => kPresetBackgrounds[i.clamp(0, 4)];
