/// 设备性能分级（v1.6.0）
///
/// 进入 Pet Mood Capture 时自动检测芯片/内存，分为三档：
///  - recommended：完美流畅体验（完整开启 HRNet 体态识别）
///  - minimum    ：可运行，可能掉帧/发热（弹窗询问是否继续）
///  - legacy     ：默认关闭体态识别（仅音频；可手动强制开启）
///
/// 检测优先级：原生层读取真实芯片型号（Android: Build.SOC_MODEL/BOARD；
/// iOS: systemInfo machine）最为准确；若原生返回 unknown，则用 Dart 端
/// device_info_plus 的型号字符串做关键词兜底解析。
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';

enum DeviceTier { recommended, minimum, legacy, unknown }

/// 三档对应的建议默认体态状态
bool defaultPostureOn(DeviceTier t) => t == DeviceTier.recommended;

class DeviceCapability {
  static const MethodChannel _ch = MethodChannel('meowwoof/device');

  static bool _nativeHooked = false;

  /// 原生 → Dart：实时回传设备信息/tier 变更
  static void Function(Map<Object?, Object?>)? onDeviceInfo;

  static void _hookOnce() {
    if (_nativeHooked) return;
    _nativeHooked = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onDeviceInfo') {
        onDeviceInfo?.call(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
  }

  /// 检测设备分级。返回 tier + 芯片名 + 内存（MB）。
  static Future<DeviceInfoResult> detect() async {
    _hookOnce();
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('detect');
      if (r != null && r['tier'] is String) {
        return DeviceInfoResult(
          tier: _parseTier(r['tier'] as String),
          chip: (r['chip'] as String?) ?? '',
          ramMb: (r['ramMb'] as num?)?.toInt() ?? 0,
          fromNative: true,
        );
      }
    } on PlatformException catch (_) {
      // 落到 Dart 兜底解析
    }
    return _detectFallback();
  }

  static DeviceTier _parseTier(String s) {
    switch (s) {
      case 'recommended':
        return DeviceTier.recommended;
      case 'minimum':
        return DeviceTier.minimum;
      case 'legacy':
        return DeviceTier.legacy;
      default:
        return DeviceTier.unknown;
    }
  }

  /// Dart 端兜底：device_info_plus 读型号字符串，关键词匹配 SoC。
  /// 仅 Android 可靠；iOS 在无原生时返回 unknown（由原生补全）。
  static Future<DeviceInfoResult> _detectFallback() async {
    try {
      final di = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await di.androidInfo;
        // device_info_plus 10.x 无 socModel（11+ 才有），用 board/hardware/model 兜底
        final soc = '${a.board} ${a.hardware} ${a.model}'.toLowerCase();
        // device_info_plus 10.x 无 physicalMemoryInBytes；Dart 兜底拿不到内存时给 0
        // （真实 RAM 由原生 DeviceCapability 通道补全，此处仅作降级估计）
        const ramMb = 0;
        return DeviceInfoResult(
          tier: _tierFromSocString(soc, ramMb),
          chip: a.board.isNotEmpty ? a.board : a.model,
          ramMb: ramMb,
          fromNative: false,
        );
      }
    } catch (_) {}
    return const DeviceInfoResult(
        tier: DeviceTier.unknown, chip: '', ramMb: 0, fromNative: false);
  }

  /// 关键词兜底分级（与原生逻辑保持一致的中文/英文厂商命名）。
  static DeviceTier _tierFromSocString(String soc, int ramMb) {
    // 推荐档：A14+ / 骁龙888+ / 天玑8000+
    if (soc.contains(RegExp(
        r'sm8350|sm8450|sm8475|sm8550|sm8580|sm8650|sd 8|snapdragon 8|'
        r'sc8280|cx|dimensity 8|dimensity 9|mt698|mt689|mt6983|mt6985|'
        r'kirin 9|exynos 21|exynos 22|a14|a15|a16|a17|a18'))) {
      return DeviceTier.recommended;
    }
    if (soc.contains(RegExp(
        r'sm7325|sm7375|sm7450|sm7480|sd 7|snapdragon 7|'
        r'dimensity 7|mt688|mt687|mt685|mt683|exynos 13|exynos 14|a13'))) {
      return DeviceTier.minimum;
    }
    // 老旧档：A11 及更早 / 骁龙845 及更早 / 天玑7000 同级以下
    if (soc.contains(RegExp(
        r'sm8150|sm8150|sm8250|sd 855|sd 865|sd 870|snapdragon 855|'
        r'snapdragon 865|snapdragon 870|a11|a12|msm89|sd 6|'
        r'dimensity 6|mt67|exynos 9|exynos 10|kirin 9[0-8]'))) {
      return DeviceTier.legacy;
    }
    // 内存 8GB+ 且型号不明，保守给 minimum（避免误关）。
    if (ramMb >= 8 * 1024) return DeviceTier.minimum;
    return DeviceTier.unknown;
  }
}

class DeviceInfoResult {
  final DeviceTier tier;
  final String chip;
  final int ramMb;
  final bool fromNative;
  const DeviceInfoResult({
    required this.tier,
    required this.chip,
    required this.ramMb,
    required this.fromNative,
  });

  String get tierLabel {
    switch (tier) {
      case DeviceTier.recommended:
        return '推荐机型';
      case DeviceTier.minimum:
        return '最低兼容机型';
      case DeviceTier.legacy:
        return '老旧机型';
      case DeviceTier.unknown:
        return '未知机型';
    }
  }
}
