/// 毛语通 · 语音桥接（Android MethodChannel 封装）
///
/// 通道 meowwoof/voice，原生端见 MainActivity.kt。
/// Web/桌面端不支持时会安全降级（hasNative == false）。
library;

import 'package:flutter/services.dart';

class VoiceBridge {
  static const MethodChannel _ch = MethodChannel('meowwoof/voice');

  static bool _nativeAvailable = true;

  /// 当前平台是否有可用原生实现（Android true，其他 false）
  static bool get hasNative => _nativeAvailable;

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on MissingPluginException {
      _nativeAvailable = false;
      rethrow;
    }
  }

  static Future<String> buildVersion() => _guard(
      () async => await _ch.invokeMethod<String>('buildVersion') ?? 'unknown');

  static Future<bool> hasMicPermission() =>
      _guard(() async => await _ch.invokeMethod<bool>('hasMicPermission') ?? false);

  static Future<bool> requestMicPermission() => _guard(
      () async => await _ch.invokeMethod<bool>('requestMicPermission') ?? false);

  /// 初始化 Vosk 模型（首次约 1~3 秒），返回 'ready'
  static Future<String> initModel() =>
      _guard(() async => await _ch.invokeMethod<String>('initModel') ?? '');

  /// grammar：JSON 数组字符串（词表语法），null = 自由听写
  static Future<bool> startListening(String? grammar) => _guard(
      () async => await _ch.invokeMethod<bool>(
          'startListening', {'grammar': grammar}) ?? false);

  static Future<bool> stopListening() =>
      _guard(() async => await _ch.invokeMethod<bool>('stopListening') ?? false);

  static Future<bool> startPetRecording() =>
      _guard(() async => await _ch.invokeMethod<bool>('startPetRecording') ?? false);

  /// 返回 {path, durationMs, f0, voicedRatio}
  static Future<Map<Object?, Object?>> stopPetRecording() => _guard(
      () async => await _ch.invokeMethod<Map<Object?, Object?>>('stopPetRecording') ?? {});

  /// asset：assets/ 相对路径；rate：播放速率（0.7~1.3）；repeat：连播次数（1 不重复）
  static Future<Map<Object?, Object?>> playCall(String asset, double rate,
          {int repeat = 1}) =>
      _guard(() async => await _ch.invokeMethod<Map<Object?, Object?>>(
          'playCall', {'asset': asset, 'rate': rate, 'repeat': repeat}) ?? {});

  static Future<bool> stopPlaying() =>
      _guard(() async => await _ch.invokeMethod<bool>('stopPlaying') ?? false);

  // ---- 原生 → Dart 事件 ----

  static void setHandlers({
    void Function(String json)? onPartial,
    void Function(String json)? onFinal,
    void Function(String message)? onError,
  }) {
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPartial':
          onPartial?.call(call.arguments as String? ?? '');
          break;
        case 'onFinal':
          onFinal?.call(call.arguments as String? ?? '');
          break;
        case 'onError':
          onError?.call(call.arguments as String? ?? '识别出错');
          break;
      }
      return null;
    });
  }
}

/// 从 Vosk JSON（{"partial": "..."} 或 {"text": "..."}）提取文本
String textFromVoskJson(String json) {
  // 轻量解析，避免引入 dart:convert 之外的依赖——dart:convert 是 SDK 自带
  final partial = RegExp(r'"partial"\s*:\s*"([^"]*)"').firstMatch(json);
  if (partial != null) return partial.group(1) ?? '';
  final text = RegExp(r'"text"\s*:\s*"([^"]*)"').firstMatch(json);
  if (text != null) return text.group(1) ?? '';
  return '';
}
