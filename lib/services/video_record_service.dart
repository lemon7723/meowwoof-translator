/// 相机捕获 + 实时体态推理 + 音画同步录像 + 边录边叫（v1.6.0）
///
/// 桥接原生通道 meowwoof/capture：相机预览由原生平台视图（AndroidView,
/// viewType = 'meowwoof/camera_preview'）渲染，原生端同时做：
///  - SSD 前置检测（画面无猫狗则跳过姿态推理）
///  - HRNet 实时姿态推理（默认每 2~3 帧一次，A13 强制每 3 帧）
///  - 暗光检测（亮度低于阈值 → 禁用体态，UI 提示）
///  - 麦克风分流：一路送音频识别，一路送录像编码器（音画严格对齐）
///  - 录像导出 MP4（画面 + 麦克风原声 + 实时情绪文字叠加）
///  - 边录边叫：播放选中预设叫声 + 录像同时录制该音频
///
/// 所有异常只在原生 capture 通道内以 result.error 返回，绝不抛到 Flutter 外，
/// 不影响音频/叫声库等其它模块（需求 6 / 10）。
library;

import 'package:flutter/services.dart';

/// 实时体态/亮度事件
class CaptureEvent {
  final String? postureEmotion; // 当前体态情绪文案（null = 无宠物/未识别）
  final String? postureDetail;
  final bool lowLight; // 暗光：已禁用体态识别
  final bool hasPet; // SSD 是否检测到猫狗
  const CaptureEvent({
    this.postureEmotion,
    this.postureDetail,
    this.lowLight = false,
    this.hasPet = false,
  });
}

class VideoRecordService {
  static const MethodChannel _ch = MethodChannel('meowwoof/capture');
  static bool _hooked = false;

  static void Function(CaptureEvent)? onCaptureEvent;
  static void Function(bool recording)? onRecordState;

  static void _hookOnce() {
    if (_hooked) return;
    _hooked = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCapture':
          final m = call.arguments as Map<Object?, Object?>;
          onCaptureEvent?.call(CaptureEvent(
            postureEmotion: m['emotion'] as String?,
            postureDetail: m['detail'] as String?,
            lowLight: (m['lowLight'] as bool?) ?? false,
            hasPet: (m['hasPet'] as bool?) ?? false,
          ));
          break;
        case 'onRecordState':
          onRecordState?.call((call.arguments as bool?) ?? false);
          break;
      }
      return null;
    });
  }

  /// 打开相机（原生平台视图渲染预览）。
  /// [postureEnabled] 体态识别总开关；[isA13] 是否为 A13 等设备（强制每 3 帧）。
  static Future<bool> open({required bool postureEnabled, bool isA13 = false}) async {
    _hookOnce();
    try {
      final r = await _ch.invokeMethod<bool>('open', {
        'postureEnabled': postureEnabled,
        'isA13': isA13,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '相机打开失败');
    }
  }

  static Future<void> close() async {
    try {
      await _ch.invokeMethod<dynamic>('close');
    } on PlatformException catch (_) {}
  }

  /// 开始实时姿态推理（节流由原生按帧率/A13 执行）。
  static Future<void> startPosture() async {
    try {
      await _ch.invokeMethod<dynamic>('startPosture');
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '实时推理启动失败');
    }
  }

  static Future<void> stopPosture() async {
    try {
      await _ch.invokeMethod<dynamic>('stopPosture');
    } on PlatformException catch (_) {}
  }

  /// 开始音画同步录像（画面 + 麦克风原声 + 情绪文字叠加）。
  static Future<bool> startRecording() async {
    try {
      final r = await _ch.invokeMethod<bool>('startRecord');
      return r ?? false;
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '录像启动失败');
    }
  }

  /// 停止录像，返回导出 MP4 路径。
  static Future<String?> stopRecording() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('stopRecord');
      return r?['path'] as String?;
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '录像停止失败');
    }
  }

  /// 边录边叫：播放选中预设叫声（音画严格对齐，音频进入录像文件）。
  /// [asset] assets/sounds 相对路径；[rate] 播放速率。
  static Future<void> playCallDuringRecording(String asset, double rate) async {
    try {
      await _ch.invokeMethod<dynamic>(
          'playCall', {'asset': asset, 'rate': rate});
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '边录边叫播放失败');
    }
  }

  /// 停止边录边叫的叫声播放（录像继续）。
  static Future<void> stopCallDuringRecording() async {
    try {
      await _ch.invokeMethod<dynamic>('stopCall');
    } on PlatformException catch (_) {}
  }
}

class CaptureException implements Exception {
  final String code;
  final String message;
  CaptureException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}
