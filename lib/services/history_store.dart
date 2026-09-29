/// 识别历史统一存储（v1.6.0）
///
/// 汇总两类记录，供「识别历史」页展示：
/// - pose：体态识别（图片路径、物种、情绪、置信度、时间）
/// - audio：录音识别（音频路径、物种、情绪、时长、时间）
/// 本地 SharedPreferences 持久化，最多 50 条，FIFO。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class HistoryItem {
  final String kind; // 'pose' | 'audio'
  final String mediaPath; // 图片/音频路径（可能已被清理，展示时判空）
  final String species; // 'cat' | 'dog'
  final String emotion; // 情绪标签
  final String detail; // 补充说明
  final double? conf; // 置信度（体态有，录音可无）
  final int createdAtMs;

  HistoryItem({
    required this.kind,
    required this.mediaPath,
    required this.species,
    required this.emotion,
    required this.detail,
    this.conf,
    required this.createdAtMs,
  });

  Map<String, Object?> toMap() => {
        'kind': kind,
        'media': mediaPath,
        'species': species,
        'emotion': emotion,
        'detail': detail,
        'conf': conf,
        'at': createdAtMs,
      };

  static HistoryItem fromMap(Map<Object?, Object?> m) => HistoryItem(
        kind: (m['kind'] as String?) ?? 'audio',
        mediaPath: (m['media'] as String?) ?? '',
        species: (m['species'] as String?) ?? 'cat',
        emotion: (m['emotion'] as String?) ?? '',
        detail: (m['detail'] as String?) ?? '',
        conf: (m['conf'] as num?)?.toDouble(),
        createdAtMs: (m['at'] as num?)?.toInt() ?? 0,
      );
}

class HistoryStore {
  static const int maxCount = 50;
  static const _key = 'history_v1';

  /// 新增一条（新的在前，超 50 条 FIFO）
  static Future<void> add(HistoryItem item) async {
    final sp = await SharedPreferences.getInstance();
    final list = _load(sp);
    list.insert(0, item);
    while (list.length > maxCount) {
      list.removeLast();
    }
    await sp.setString(_key, jsonEncode(list.map((e) => e.toMap()).toList()));
  }

  /// 全部记录（新的在前）
  static Future<List<HistoryItem>> all() async {
    final sp = await SharedPreferences.getInstance();
    return _load(sp);
  }

  /// 清空
  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_key);
  }

  static List<HistoryItem> _load(SharedPreferences sp) {
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => HistoryItem.fromMap((e as Map).cast<Object?, Object?>()))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
