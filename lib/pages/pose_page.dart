/// 体态识别 / Pet Mood Capture 页（v1.6.0 重写）
///
/// 主流程（需求 2~9）：进入页面 → 设备分级检测 + 三档弹窗（可"不再提示"）
/// → 一次性申请相机/麦克风权限 → 远端下载 HRNet 模型（失败则禁用体态，音频保留）
/// → 相机实时预览 + 实时姿态推理（每 2~3 帧；A13 每 3 帧）+ 情绪叠字
/// → 暗光自动禁用体态 → 音画同步录像（麦克风分流）→ 边录边叫
/// → 导出 MP4（画面+原声+情绪字幕）→ 多平台一键分享。
///
/// 保留（需求 10）：原有"拍照/相册单张识别"作为相机不可用时的兜底入口。
/// 免责声明改为右上角 ⓘ 图标按钮，点击才弹窗（不再进页面自动弹）。
///
/// 开发备注（需求 11）：24 点关键点映射见原生 PoseRules.kt；姿态情绪融合逻辑
/// 见 PoseRules + EmotionFusion + PoseService.merge；边录边叫音画同步逻辑见
/// 原生 CameraRecorder.kt（麦克风分流）；海外一键转发逻辑见 ShareService / 原生 ShareManager。
library;

import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' show kSeed;
import '../data/call_library.dart';
import '../services/device_capability.dart';
import '../services/history_store.dart';
import '../services/pose_service.dart';
import '../services/profile_store.dart';
import '../services/share_service.dart';
import '../services/video_record_service.dart';

class PosePage extends StatefulWidget {
  final PetProfile pet;
  const PosePage({super.key, required this.pet});

  @override
  State<PosePage> createState() => _PosePageState();
}

class _PosePageState extends State<PosePage> {
  String _stage = 'init'; // init / ready / recording / done
  int _downloadProgress = 0;
  String? _error;

  // 设备分级
  DeviceTier _tier = DeviceTier.unknown;
  bool _tierDlgDone = false;

  // 设置
  late AppSettings _settings;
  bool _postureEnabled = true;

  // 相机 / 实时
  bool _cameraReady = false;
  bool _lowLight = false;
  bool _hasPet = false;
  String? _liveEmotion;
  String? _liveDetail;
  bool _isA13 = false; // 低端设备（A13/同档）强制每 3 帧

  // 录像 / 分享
  bool _recording = false;
  int _recSecs = 0;
  Timer? _recTick;
  String? _recordedPath;
  Map<SocialApp, bool> _installed = {};

  // 边录边叫
  int? _playingCallIdx;

  @override
  void initState() {
    super.initState();
    VideoRecordService.onCaptureEvent = _onCapture;
    VideoRecordService.onRecordState = (r) {
      if (mounted) setState(() => _recording = r);
    };
    _boot();
  }

  @override
  void dispose() {
    _recTick?.cancel();
    VideoRecordService.onCaptureEvent = null;
    VideoRecordService.onRecordState = null;
    VideoRecordService.stopPosture().catchError((_) {});
    VideoRecordService.close().catchError((_) {});
    super.dispose();
  }

  Future<void> _boot() async {
    _settings = await ProfileStore.loadSettings();
    _postureEnabled = _settings.postureEnabled;
    if (!mounted) return;

    // —— 1. 设备分级检测（需求 6）——
    final info = await DeviceCapability.detect();
    _tier = info.tier;
    _isA13 = _tier == DeviceTier.minimum; // 最低兼容档（含 A13）强制每 3 帧
    _settings = _settings.copyWith(deviceTier: _tier.name);
    await ProfileStore.saveSettings(_settings);
    if (!mounted) return;
    setState(() {});

    // —— 2. 三档弹窗（可"不再提示"）——
    if (!_settings.deviceTierAcked && _tier != DeviceTier.recommended) {
      await _showTierDialog(_tier);
    } else {
      _tierDlgDone = true;
    }
    if (!mounted) return;

    // —— 3. 权限：相机 + 麦克风（需求 8.3）——
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!mounted) return;
    if (cam.isDenied || mic.isDenied) {
      setState(() {
        _error = '需要相机与麦克风权限才能使用 Pet Mood Capture。'
            '请到系统设置 → 应用 → 宠了么 → 权限，允许后重进本页。'
            '（音频相关功能仍可正常使用）';
      });
      return;
    }

    // —— 4. 模型下载（仅体态开启时）——
    if (_postureEnabled) {
      setState(() => _stage = 'downloading');
      PoseService.onModelProgress = (p) {
        if (mounted) setState(() => _downloadProgress = p);
      };
      try {
        await PoseService.prepareModel();
      } on PoseException catch (e) {
        // 降级（需求 2）：模型下载失败 → 禁用体态，音频保留
        _postureEnabled = false;
        _settings = _settings.copyWith(postureEnabled: false);
        await ProfileStore.saveSettings(_settings);
        if (mounted) {
          setState(() {
            _error = '模型下载失败（${e.message}）。体态识别已停用，'
                '录音与叫声功能不受影响。请检查网络后重进本页。';
          });
        }
      }
    }

    // —— 5. 打开相机（需求 4 实时视频流）——
    try {
      _cameraReady = await VideoRecordService.open(
          postureEnabled: _postureEnabled, isA13: _isA13);
    } on CaptureException catch (e) {
      _cameraReady = false;
      if (mounted) setState(() => _error = '相机打开失败：${e.message}');
    }
    if (!mounted) return;
    if (_postureEnabled && _cameraReady) {
      try {
        await VideoRecordService.startPosture();
      } on CaptureException catch (_) {}
    }
    if (mounted) setState(() => _stage = 'ready');
  }

  void _onCapture(CaptureEvent e) {
    if (!mounted) return;
    setState(() {
      _lowLight = e.lowLight;
      _hasPet = e.hasPet;
      _liveEmotion = e.postureEmotion;
      _liveDetail = e.postureDetail;
      // 暗光 → 禁用体态（需求 3），UI 提示
      if (e.lowLight && _postureEnabled && _recording == false) {
        // 仅提示，native 已停止推理；用户可在有光后重进或开关
      }
    });
  }

  // ---------------- 设备分级弹窗（需求 6） ----------------

  Future<void> _showTierDialog(DeviceTier tier) async {
    bool dontShow = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (c, setSt) => AlertDialog(
            title: Text(tier == DeviceTier.legacy
                ? '设备性能不足'
                : '设备性能提示'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tier == DeviceTier.legacy
                      ? 'Your device does not have enough computing power for smooth posture detection. You can only use audio features.'
                      : 'This device can run posture detection, but may experience frame drops and heating. Continue?'),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: dontShow,
                    title: const Text('不再提示'),
                    onChanged: (v) {
                      dontShow = v ?? false;
                      setSt(() {});
                    },
                  ),
                ],
              ),
            ),
            actions: [
              if (tier == DeviceTier.legacy) ...[
                TextButton(
                  onPressed: () {
                    _postureEnabled = false;
                    Navigator.pop(ctx, {'posture': false, 'dont': dontShow});
                  },
                  child: const Text('Use Audio Only'),
                ),
                TextButton(
                  onPressed: () {
                    _postureEnabled = true;
                    _settings =
                        _settings.copyWith(forcePosture: true);
                    Navigator.pop(ctx, {'posture': true, 'force': true, 'dont': dontShow});
                  },
                  child: const Text('Force Enable Posture Detection (Not Recommended)'),
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    _postureEnabled = false;
                    Navigator.pop(ctx, {'posture': false, 'dont': dontShow});
                  },
                  child: const Text('Turn off posture detection'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, {'posture': true, 'dont': dontShow}),
                  child: const Text('Continue'),
                ),
              ],
            ],
          ),
        );
      },
    );
    if (result != null) {
      _postureEnabled = result['posture'] as bool;
      _settings = _settings.copyWith(
        postureEnabled: _postureEnabled,
        forcePosture: result['force'] as bool? ?? false,
        deviceTierAcked: (result['dont'] as bool? ?? false),
      );
      await ProfileStore.saveSettings(_settings);
    }
    _tierDlgDone = true;
    if (mounted) setState(() {});
  }

  // ---------------- 体态开关（全局常驻，需求 6） ----------------

  Future<void> _togglePosture(bool on) async {
    _postureEnabled = on;
    _settings = _settings.copyWith(postureEnabled: on);
    await ProfileStore.saveSettings(_settings);
    if (!mounted) return;
    setState(() {});
    if (on) {
      if (_cameraReady) {
        try {
          await VideoRecordService.startPosture();
        } on CaptureException catch (_) {}
      }
    } else {
      await VideoRecordService.stopPosture().catchError((_) {});
    }
  }

  // ---------------- 录像（需求 8 音画同步） ----------------

  Future<void> _toggleRecord() async {
    if (_recording) {
      _recTick?.cancel();
      try {
        final path = await VideoRecordService.stopRecording();
        if (path != null) {
          _recordedPath = path;
          // 分享按钮前先检测已安装 App（需求 9.1）
          await _refreshInstalled();
        }
        if (mounted) setState(() => _stage = 'done');
      } on CaptureException catch (e) {
        if (mounted) setState(() => _error = '录像保存失败：${e.message}');
      }
    } else {
      try {
        final ok = await VideoRecordService.startRecording();
        if (!ok) {
          if (mounted) setState(() => _error = '录像启动失败（麦克风/相机不可用）');
          return;
        }
        _recSecs = 0;
        _recTick = Timer.periodic(const Duration(seconds: 1), (t) {
          if (mounted) setState(() => _recSecs++);
        });
        if (mounted) setState(() => _stage = 'recording');
      } on CaptureException catch (e) {
        if (mounted) setState(() => _error = '录像启动失败：${e.message}');
      }
    }
  }

  Future<void> _refreshInstalled() async {
    _installed = await ShareService.checkInstalled([
      SocialApp.tiktok,
      SocialApp.instagram,
      SocialApp.x,
      SocialApp.facebook,
      SocialApp.youtube,
    ]);
    if (mounted) setState(() {});
  }

  // 边录边叫（需求 8.1）：选预设叫声 → 播放并进入录像音轨
  Future<void> _pickAndPlayCall() async {
    final species = widget.pet.species;
    final idx = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('边录边叫：选一个叫声，录音同时播放',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (var i = 0; i < kIntents.length; i++)
              ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(kIntents[i].name),
                subtitle: Text(kIntents[i].phonetic(species)),
                onTap: () => Navigator.pop(ctx, i),
              ),
          ],
        ),
      ),
    );
    if (idx == null) return;
    final asset = callAsset(species, kIntents[idx].id, idx);
    try {
      await VideoRecordService.playCallDuringRecording(
          asset, widget.pet.playbackRate);
      if (mounted) setState(() => _playingCallIdx = idx);
    } on CaptureException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('边录边叫失败：${e.message}')));
      }
    }
  }

  // ---------------- 照片兜底（需求 10 保留） ----------------

  Future<void> _pickPhoto(ImageSource src) async {
    try {
      final x = await ImagePicker().pickImage(source: src, imageQuality: 90);
      if (x == null) return;
      setState(() => _error = null);
      final r = await PoseService.inferFromPath(x.path, widget.pet.species);
      if (!r.found) {
        if (mounted) setState(() => _error = '未识别到宠物，请光线充足、完整拍到宠物全身。');
        return;
      }
      final f = await PoseService.merge(null, r.poseEmotion);
      if (mounted) {
        setState(() {
          _liveEmotion = r.poseEmotion;
          _liveDetail = r.detail;
          _recordedPath = null;
          _stage = 'done';
        });
        await HistoryStore.add(HistoryItem(
          kind: 'pose',
          mediaPath: x.path,
          species: widget.pet.species,
          emotion: r.poseEmotion ?? '',
          detail: r.detail ?? '',
          conf: r.conf,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ));
        setState(() => _fusionResult = f);
      }
    } on PoseException catch (e) {
      if (mounted) setState(() => _error = '体态识别失败：${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = '体态识别异常：$e');
    }
  }

  FusionResult? _fusionResult;

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Pet Mood Capture'),
        actions: [
          IconButton(
            tooltip: '免责声明',
            icon: const Icon(Icons.info_outline),
            onPressed: _showDisclaimerDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _previewArea(cs)),
            if (_error != null) _errorBar(cs),
            _controls(cs),
          ],
        ),
      ),
    );
  }

  Widget _previewArea(ColorScheme cs) {
    if (_stage == 'downloading') {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('正在下载体态模型（约 54.6MB，仅首次）……',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: LinearProgressIndicator(value: _downloadProgress / 100),
          ),
          const SizedBox(height: 6),
          Text('$_downloadProgress %', style: const TextStyle(color: Colors.white54)),
        ],
      );
    }
    // 相机预览（Android 平台视图；iOS / 不支持时降级为照片兜底提示）
    if (!_cameraReady) {
      // 相机不可用：仅提示；「拍照识别 / 从相册选」已下移到 _controls 常驻展示，避免重复。
      return Stack(
        children: [
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.pets, size: 56, color: Colors.white38),
                const SizedBox(height: 8),
                const Text('相机实时预览需要 Android 设备',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 4),
                const Text('（仍可使用下方「拍照识别 / 从相册选」）',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ],
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        const AndroidView(
          viewType: 'meowwoof/camera_preview',
          creationParams: <String, dynamic>{},
          creationParamsCodec: StandardMessageCodec(),
        ),
        // 实时情绪叠字（native 也会烧录进录像；此处为实时 HUD）
        if (_liveEmotion != null && !_lowLight)
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('体态情绪：$_liveEmotion',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  if (_liveDetail != null)
                    Text(_liveDetail!,
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ),
        // 暗光提示（需求 3）
        if (_lowLight)
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(10)),
              child: const Text('Low light, posture detection disabled',
                  style: TextStyle(color: Colors.orangeAccent)),
            ),
          ),
        // 录制中计时
        if (_recording)
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  const Icon(Icons.circle, size: 10, color: Colors.white),
                  const SizedBox(width: 6),
                  Text('REC $_recSecs s',
                      style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _errorBar(ColorScheme cs) {
    return Container(
      color: cs.errorContainer.withOpacity(0.95),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _error = null),
          ),
        ],
      ),
    );
  }

  Widget _controls(ColorScheme cs) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: Column(
        children: [
          // 体态识别开关（全局常驻，需求 6）
          SwitchListTile(
            activeColor: kSeed,
            contentPadding: EdgeInsets.zero,
            title: const Text('体态识别', style: TextStyle(color: Colors.white)),
            subtitle: Text(
              _postureEnabled ? '实时分析宠物肢体语言' : '已关闭（仅音频）',
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
            value: _postureEnabled,
            onChanged: _togglePosture,
          ),
          const SizedBox(height: 8),
          // 录制按钮 / 边录边叫
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _recording ? Colors.red : kSeed),
                  onPressed: _toggleRecord,
                  icon: Icon(_recording ? Icons.stop : Icons.videocam),
                  label: Text(_recording ? '停止录像' : '开始录像'),
                ),
              ),
              if (_recording) ...[
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _pickAndPlayCall,
                  icon: const Icon(Icons.campaign),
                  label: Text(_playingCallIdx != null ? '切换叫声' : '边录边叫'),
                ),
              ],
            ],
          ),
          // 常驻：拍照识别 / 从相册选（需求 10 原有控件，正常预览态也展示，不只在相机降级分支）
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _pickPhoto(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('拍照识别'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickPhoto(ImageSource.gallery),
                  icon: const Icon(Icons.photo),
                  label: const Text('从相册选'),
                ),
              ),
            ],
          ),
          if (_stage == 'done' && _recordedPath != null) _shareRow(cs),
          if (_stage == 'done' && _fusionResult != null) _photoResult(cs),
        ],
      ),
    );
  }

  Widget _shareRow(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('分享你的作品', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _shareBtn(SocialApp.tiktok, cs),
            _shareBtn(SocialApp.instagram, cs),
            _shareBtn(SocialApp.x, cs),
            _shareBtn(SocialApp.facebook, cs),
            _shareBtn(SocialApp.youtube, cs),
            OutlinedButton.icon(
              onPressed: () => ShareService.systemShare(_recordedPath!,
                  subject: 'Pet Mood Capture'),
              icon: const Icon(Icons.share),
              label: const Text('System Share'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _shareBtn(SocialApp app, ColorScheme cs) {
    final installed = _installed[app] ?? false;
    return Opacity(
      opacity: installed ? 1.0 : 0.5,
      child: OutlinedButton.icon(
        onPressed: installed
            ? () async {
                final msg = await ShareService.shareTo(app, _recordedPath!);
                if (msg != null && mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(msg)));
                }
              }
            : null,
        icon: const Icon(Icons.send),
        // 需求 9.1：未安装则按钮置灰并提示 "App not installed"
        label: Text(installed
            ? app.label.replaceFirst('Share to ', '')
            : 'App not installed'),
      ),
    );
  }

  Widget _photoResult(ColorScheme cs) {
    final f = _fusionResult!;
    return Card(
      color: Colors.grey.shade900,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('识别结果', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('叫声情绪：${f.audioEmotion ?? "（本通道无结果）"}',
                style: const TextStyle(color: Colors.white)),
            Text('体态情绪：${f.poseEmotion ?? "（本通道无结果）"}',
                style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 6),
            Text(f.conclusion, style: const TextStyle(color: kSeed, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  void _showDisclaimerDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('宠了么仅为宠物趣味AI体态、叫声娱乐识别工具，'
                  '识别结果仅供娱乐参考，不能替代兽医专业诊断。'),
              SizedBox(height: 6),
              Text('AI姿态识别受光线、拍摄角度、遮挡影响，存在误判概率；'
                  '请勿仅凭本App结果判断宠物健康状态。'),
              SizedBox(height: 6),
              Text('体态模型使用 SuperAnimal HRNet-w32（INT8 量化），'
                  '遵循 Apache-2.0 开源协议。'),
              SizedBox(height: 6),
              Text('暗光环境下肢体/耳朵/尾巴关键点检测不准，'
                  '本App会自动关闭体态分析，仅保留音频功能。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('我已知晓'),
          ),
        ],
      ),
    );
  }
}
