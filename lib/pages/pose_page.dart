/// 体态识别页（v1.4.0）
///
/// 流程：进入页面 → 权限检查（拒绝则整页禁用）→ 模型下载（进度条/重试/
/// 断点续传在原生层）→ 相机/相册选图 → 推理 → 三栏展示
/// （叫声情绪 / 体态情绪 / 综合解读）+ 底部免责声明。
/// 本页任何异常只影响本页，不触碰首页录音与叫声库（需求 6）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart' show kSeed;
import '../services/pose_service.dart';
import '../services/profile_store.dart';

class PosePage extends StatefulWidget {
  final PetProfile pet;
  const PosePage({super.key, required this.pet});

  @override
  State<PosePage> createState() => _PosePageState();
}

class _PosePageState extends State<PosePage> {
  String _stage = 'checking'; // checking / perm-denied / downloading / ready / infering / done
  int _progress = 0;
  String? _error;
  String? _imagePath;
  String? _audioEmotion;
  String? _poseEmotion;
  String? _poseDetail;
  double? _poseConf;
  FusionResult? _fusion;

  static const _disclaimer =
      '本结果仅趣味参考，不能作为宠物医疗诊断依据。';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // 模型下载不需要危险权限；图片入口的权限在选择时再请求。
    // 权限拒绝 → 隐藏图片入口（按钮），模型预下载照常进行。
    setState(() => _stage = 'downloading');
    PoseService.onModelProgress = (p) {
      if (mounted) setState(() => _progress = p);
    };
    try {
      await PoseService.prepareModel();
      if (mounted) setState(() => _stage = 'ready');
    } on PoseException catch (e) {
      if (mounted) {
        setState(() {
          _stage = 'done'; // 功能禁用但页面可展示错误
          _error = '模型下载失败（${e.message}）。体态识别已停用，'
              '录音与叫声功能不受影响。请检查网络后重进本页。';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = 'done';
          _error = '体态模块初始化失败：$e（其他功能不受影响）';
        });
      }
    }
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final picker = ImagePicker();
      final x = await picker.pickImage(source: src, imageQuality: 90);
      if (x == null) return;
      setState(() {
        _imagePath = x.path;
        _stage = 'infering';
        _error = null;
        _poseEmotion = null;
        _fusion = null;
      });
      final species = widget.pet.species;
      final r = await PoseService.inferFromPath(x.path, species);
      if (!mounted) return;
      if (!r.found) {
        setState(() {
          _stage = 'ready';
          _error = '未识别到宠物，请光线充足、完整拍到宠物全身。';
        });
        return;
      }
      setState(() {
        _poseEmotion = r.poseEmotion;
        _poseDetail = r.detail;
        _poseConf = r.conf;
        // 音频情绪：暂用最近一次播放/识别的意图映射（占位数据源）。
        // 音频通道没有结果时传 null → 融合走"单方展示"兜底。
        _stage = 'done';
      });
      await _fuse();
    } on PoseException catch (e) {
      if (mounted) {
        setState(() {
          _stage = 'ready';
          _error = '体态识别失败：${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = 'ready';
          _error = '体态识别异常：$e（录音与叫声功能不受影响）';
        });
      }
    }
  }

  /// 设置音频情绪并融合（供外部把"最近一次叫声识别结果"接进来）
  Future<void> _fuse() async {
    try {
      final f = await PoseService.merge(_audioEmotion, _poseEmotion);
      if (mounted) setState(() => _fusion = f);
    } catch (e) {
      if (mounted) setState(() => _error = '融合判断失败：$e');
    }
  }

  /// 供外部注入音频情绪（例如翻译页识别到指令后跳转本页时）
  void setAudioEmotion(String? emotion) {
    _audioEmotion = emotion;
    _fuse();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('体态观察', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '拍一张宠物全身照，结合叫声情绪给出综合解读。'
                  '本页为通用姿态模型的近似判断。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_stage == 'downloading') ...[
                  const Text('正在下载体态模型（约 4MB，仅首次）……'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _progress / 100),
                  const SizedBox(height: 4),
                  Text('$_progress %', style: Theme.of(context).textTheme.bodySmall),
                ],
                if (_error != null) ...[
                  Card(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!,
                          style: TextStyle(color: cs.onErrorContainer)),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (_stage == 'ready' || _stage == 'done') _imageSection(cs),
                if (_stage == 'infering') const LinearProgressIndicator(),
                if (_stage == 'done' && _fusion != null) _resultSection(cs),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: cs.surfaceContainerHighest,
            padding: const EdgeInsets.all(10),
            child: Text(
              _disclaimer,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageSection(ColorScheme cs) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            if (_imagePath != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(_imagePath!), height: 220,
                    fit: BoxFit.cover),
              )
            else
              Container(
                height: 120,
                alignment: Alignment.center,
                child: Icon(Icons.pets, size: 48, color: cs.outline),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () => _pick(ImageSource.camera),
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('拍照识别'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () => _pick(ImageSource.gallery),
                  icon: const Icon(Icons.photo),
                  label: const Text('从相册选'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultSection(ColorScheme cs) {
    final f = _fusion!;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('识别结果', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('叫声情绪', f.audioEmotion ?? '（本通道无结果）'),
            _row('体态情绪', f.poseEmotion == null
                ? '（本通道无结果）'
                : '${f.poseEmotion}${_poseConf != null
                    ? '（置信 ${(_poseConf! * 100).toStringAsFixed(0)}%）'
                    : ''}${_poseDetail != null ? ' · $_poseDetail' : ''}'),
            const Divider(height: 16),
            Text(
              f.isSingleSource ? '单通道结果（不强行综合）' : '综合解读',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            Text(
              f.conclusion,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, color: kSeed),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
