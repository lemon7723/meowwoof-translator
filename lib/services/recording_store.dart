/// 录音记录管理（v1.5.9 P1-4）
///
/// 需求：
/// - 本地最多保存最近 10 条录音记录，FIFO 淘汰（存满删最早）
/// - 音频文件存 App 私有目录（getApplicationDocumentsDirectory/recordings/），
///   不申请外部存储权限
/// - 录音列表供「我的毛孩」页展示，可回放、可导入叫声库复用
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingItem {
  final String path; // 音频文件绝对路径（私有目录内）
  final int durationMs;
  final double f0; // 录音时分析出的基频（可能有）
  final int createdAtMs;

  RecordingItem({
    required this.path,
    required this.durationMs,
    required this.f0,
    required this.createdAtMs,
  });

  Map<String, Object?> toMap() => {
        'path': path,
        'durationMs': durationMs,
        'f0': f0,
        'createdAtMs': createdAtMs,
      };

  static RecordingItem fromMap(Map<Object?, Object?> m) => RecordingItem(
        path: (m['path'] as String?) ?? '',
        durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
        f0: (m['f0'] as num?)?.toDouble() ?? 0,
        createdAtMs: (m['createdAtMs'] as num?)?.toInt() ?? 0,
      );
}

class RecordingStore {
  static const int maxCount = 10; // FIFO 上限
  static const String _key = 'recording_list_v1';

  /// 保存一条新录音：写入列表头部，超出 10 条删最早的（文件+记录一起删）
  /// 返回淘汰的记录（供 UI 提示，可为 null）
  static Future<RecordingItem?> add(RecordingItem item) async {
    final sp = await SharedPreferences.getInstance();
    final list = _load(sp);
    RecordingItem? evicted;
    list.insert(0, item);
    while (list.length > maxCount) {
      evicted = list.removeLast();
      try {
        final f = File(evicted.path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await sp.setString(_key, jsonEncode(list.map((e) => e.toMap()).toList()));
    return evicted;
  }

  /// 全部记录（新的在前）
  static Future<List<RecordingItem>> all() async {
    final sp = await SharedPreferences.getInstance();
    return _load(sp);
  }

  /// 删除单条（文件+记录）
  static Future<void> remove(RecordingItem item) async {
    final sp = await SharedPreferences.getInstance();
    final list = _load(sp);
    list.removeWhere((e) => e.path == item.path);
    await sp.setString(_key, jsonEncode(list.map((e) => e.toMap()).toList()));
    try {
      final f = File(item.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 导入到叫声库复用：把私有目录的 wav 拷贝为持久名（防 FIFO 淘汰后失效），
  /// 返回可用的新路径。PlaybackRate 处理交给播放层。
  static Future<String?> exportForLibrary(RecordingItem item) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final libDir = Directory('${docs.path}/library_sounds');
      if (!await libDir.exists()) await libDir.create(recursive: true);
      final dst =
          File('${libDir.path}/custom_${DateTime.now().millisecondsSinceEpoch}.wav');
      final src = File(item.path);
      if (!await src.exists()) return null;
      await src.copy(dst.path);
      return dst.path;
    } catch (_) {
      return null;
    }
  }

  static List<RecordingItem> _load(SharedPreferences sp) {
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final arr = jsonDecode(raw) as List;
      return arr
          .map((e) => RecordingItem.fromMap((e as Map).cast<Object?, Object?>()))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
