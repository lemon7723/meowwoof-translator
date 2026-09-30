/// 宠了么 · 宠物资料与设置持久化（SharedPreferences + JSON）
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PetProfile {
  String name;
  String species; // 'cat' | 'dog'
  String? photoPath;
  double pitchHz; // 录音分析出的基频，0 = 未录制

  /// 首页快捷场景置顶（叫声库页图钉，按置顶顺序）
  List<String> pinnedIds;

  /// 各场景累计播放次数（首页快捷排序用）
  Map<String, int> usageCounts;

  PetProfile({
    this.name = '毛孩',
    this.species = 'cat',
    this.photoPath,
    this.pitchHz = 0,
    List<String>? pinnedIds,
    Map<String, int>? usageCounts,
  })  : pinnedIds = pinnedIds ?? [],
        usageCounts = usageCounts ?? {};

  bool get hasVoicePrint => pitchHz > 0;

  /// 音色匹配档位：以人声男低音 ~110Hz 为锚点 1.0，
  /// 宠物基频越高播放越快（音调越高）、越低播放越慢（音调越低）。
  /// 上限 1.3 / 下限 0.75，避免过度失真。
  double get playbackRate {
    if (pitchHz <= 0) return species == 'cat' ? 1.15 : 0.95;
    final ratio = pitchHz / 110.0;
    final rate = 1.0 + (math.log(ratio) / math.ln2) * 0.22;
    return rate.clamp(0.75, 1.30).toDouble();
  }

  Map<String, Object?> toMap() => {
        'name': name,
        'species': species,
        'photoPath': photoPath,
        'pitchHz': pitchHz,
        'pinned': pinnedIds,
        'usage': usageCounts,
      };

  static PetProfile fromMap(Map<Object?, Object?> m) => PetProfile(
        name: (m['name'] as String?) ?? '毛孩',
        species: (m['species'] as String?) ?? 'cat',
        photoPath: m['photoPath'] as String?,
        pitchHz: (m['pitchHz'] as num?)?.toDouble() ?? 0,
        pinnedIds:
            (m['pinned'] as List?)?.map((e) => e.toString()).toList() ?? [],
        usageCounts: (m['usage'] is Map)
            ? (m['usage'] as Map).map(
                (k, v) => MapEntry(k.toString(), (v is num ? v : 0).toInt()))
            : <String, int>{},
      );

  /// 拷贝并可选覆写部分字段（集合字段深拷贝，避免共享可变状态）
  PetProfile copyWith({
    String? name,
    String? species,
    String? photoPath,
    double? pitchHz,
    List<String>? pinnedIds,
    Map<String, int>? usageCounts,
  }) =>
      PetProfile(
        name: name ?? this.name,
        species: species ?? this.species,
        photoPath: photoPath ?? this.photoPath,
        pitchHz: pitchHz ?? this.pitchHz,
        pinnedIds: pinnedIds ?? List.of(this.pinnedIds),
        usageCounts: usageCounts ?? Map.of(this.usageCounts),
      );
}

/// 全局设置（与宠物资料分离，跨宠物生效）。
/// v1.6.0：体态识别总开关、设备分级弹窗"不再提示"、老旧机型强制开启标记。
class AppSettings {
  /// 体态识别总开关（任何机型可在设置页手动开/关）。默认开。
  bool postureEnabled;

  /// 是否已确认过设备分级弹窗（勾选"不再提示"后置 true，后续进页不再弹）。
  bool deviceTierAcked;

  /// 用户在老旧机型上手动强制开启体态识别（Not Recommended）。
  bool forcePosture;

  /// 上次检测到的设备分级结果缓存（'recommended'|'minimum'|'legacy'|'unknown'）。
  String? deviceTier;

  AppSettings({
    this.postureEnabled = true,
    this.deviceTierAcked = false,
    this.forcePosture = false,
    this.deviceTier,
  });

  /// 拷贝并可选覆写部分字段
  AppSettings copyWith({
    bool? postureEnabled,
    bool? deviceTierAcked,
    bool? forcePosture,
    String? deviceTier,
  }) =>
      AppSettings(
        postureEnabled: postureEnabled ?? this.postureEnabled,
        deviceTierAcked: deviceTierAcked ?? this.deviceTierAcked,
        forcePosture: forcePosture ?? this.forcePosture,
        deviceTier: deviceTier ?? this.deviceTier,
      );

  Map<String, Object?> toMap() => {
        'postureEnabled': postureEnabled,
        'deviceTierAcked': deviceTierAcked,
        'forcePosture': forcePosture,
        'deviceTier': deviceTier,
      };

  static AppSettings fromMap(Map<Object?, Object?> m) => AppSettings(
        postureEnabled: (m['postureEnabled'] as bool?) ?? true,
        deviceTierAcked: (m['deviceTierAcked'] as bool?) ?? false,
        forcePosture: (m['forcePosture'] as bool?) ?? false,
        deviceTier: m['deviceTier'] as String?,
      );
}

class ProfileStore {
  static const _key = 'pet_profile_v1';
  static const _settingsKey = 'app_settings_v1';
  static PetProfile? _cache;
  static AppSettings? _settingsCache;

  static Future<PetProfile> load() async {
    if (_cache != null) return _cache!;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) {
      _cache = PetProfile();
      return _cache!;
    }
    try {
      final obj = jsonDecode(raw);
      _cache = PetProfile.fromMap(obj is Map ? obj.cast<Object?, Object?>() : {});
    } catch (_) {
      _cache = PetProfile();
    }
    return _cache!;
  }

  static Future<void> save(PetProfile p) async {
    _cache = p;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(p.toMap()));
  }

  /// 拷贝头像到应用文档目录（相册临时文件可能被系统回收）
  /// v1.6.0：读取全局设置（带内存缓存）
  static Future<AppSettings> loadSettings() async {
    if (_settingsCache != null) return _settingsCache!;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_settingsKey);
    if (raw == null || raw.isEmpty) {
      _settingsCache = AppSettings();
      return _settingsCache!;
    }
    try {
      final obj = jsonDecode(raw);
      _settingsCache =
          AppSettings.fromMap(obj is Map ? obj.cast<Object?, Object?>() : {});
    } catch (_) {
      _settingsCache = AppSettings();
    }
    return _settingsCache!;
  }

  /// v1.6.0：保存全局设置
  static Future<void> saveSettings(AppSettings s) async {
    _settingsCache = s;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_settingsKey, jsonEncode(s.toMap()));
  }

  static Future<String?> importPhoto(String srcPath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dst = File(
          '${docs.path}/pet_photo_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(srcPath).copy(dst.path);
      return dst.path;
    } catch (_) {
      return null;
    }
  }
}
