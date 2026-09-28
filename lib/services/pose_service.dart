/// 体态识别服务（v1.4.0）
///
/// 与原生 PoseChannel("meowwoof/pose") 对接：模型下载（进度回调）、
/// 图片推理、情绪融合。任何异常都以 PoseException 抛出给页面层展示，
/// 绝不影响录音/播放/预设叫声（模块解耦，需求 6）。
library;

import 'package:flutter/services.dart';

class PoseException implements Exception {
  final String code;
  final String message;
  PoseException(this.code, this.message);
  @override
  String toString() => '$code: $message';
}

/// 体态推理结果
class PoseInferResult {
  final bool found; // false = 未识别到宠物（或关键点置信不足）
  final double? conf;
  final String? poseEmotion; // 紧张/烦躁/放松/愤怒/恐惧/警告/放松开心
  final String? detail;
  PoseInferResult({required this.found, this.conf, this.poseEmotion, this.detail});
}

/// 融合结果
class FusionResult {
  final String? audioEmotion;
  final String? poseEmotion;
  final String conclusion;
  final bool isSingleSource;
  FusionResult({
    required this.audioEmotion,
    required this.poseEmotion,
    required this.conclusion,
    required this.isSingleSource,
  });
}

class PoseService {
  static const MethodChannel _ch = MethodChannel('meowwoof/pose');

  static bool _progressHooked = false;

  /// 模型进度回调（原生 onProgress 推送 0-100）
  static void Function(int percent)? onModelProgress;

  static void _hookProgressOnce() {
    if (_progressHooked) return;
    _progressHooked = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final p = (call.arguments as num?)?.toInt() ?? 0;
        onModelProgress?.call(p);
      }
      return null;
    });
  }

  /// 确保模型就绪（下载/复用）。失败抛 PoseException("DOWNLOAD_FAIL")。
  static Future<void> prepareModel() async {
    _hookProgressOnce();
    try {
      await _ch.invokeMethod<dynamic>('prepareModel');
    } on PlatformException catch (e) {
      throw PoseException(e.code, e.message ?? '模型下载失败');
    } on MissingPluginException {
      throw PoseException('NO_NATIVE', '当前平台没有体态识别模块');
    }
  }

  /// 图片推理。path 为 image_picker 返回的路径。
  /// found=false 表示未识别到宠物/关键点置信不足。
  static Future<PoseInferResult> inferFromPath(String path, String species) async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>(
          'inferFromPath', {'path': path, 'species': species});
      final map = r ?? const {};
      return PoseInferResult(
        found: (map['found'] as bool?) ?? false,
        conf: (map['conf'] as num?)?.toDouble(),
        poseEmotion: map['poseEmotion'] as String?,
        detail: map['detail'] as String?,
      );
    } on PlatformException catch (e) {
      throw PoseException(e.code, e.message ?? '推理失败');
    }
  }

  /// 融合：mergePetEmotion(audioEmotion, poseEmotion)
  static Future<FusionResult> merge(String? audioEmotion, String? poseEmotion) async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>(
          'merge', {'audio': audioEmotion, 'pose': poseEmotion});
      final map = r ?? const {};
      return FusionResult(
        audioEmotion: map['audioEmotion'] as String?,
        poseEmotion: map['poseEmotion'] as String?,
        conclusion: (map['conclusion'] as String?) ?? '',
        isSingleSource: (map['isSingleSource'] as bool?) ?? false,
      );
    } on PlatformException catch (e) {
      throw PoseException(e.code, e.message ?? '融合失败');
    }
  }
}
