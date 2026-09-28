/// 毛语通 · 主界面
///
/// 三个页面：
/// 1. 翻译页 —— 按住/点击说话 → 离线识别 → 意图匹配 → 播放对应叫声
/// 2. 叫声库 —— 10 个预设叫声（猫/狗两套），逐一说明用途，可手动播放
/// 3. 我的毛孩 —— 拍照/相册设头像、改名、选猫狗、录宠物声音测音高（音色匹配）
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'data/call_library.dart';
import 'logic/translator_engine.dart';
import 'services/profile_store.dart';
import 'services/voice_bridge.dart';

void main() {
  runApp(const MeowWoofApp());
}

const Color kSeed = Color(0xFFE8722A); // 暖橙，毛孩子气质

class MeowWoofApp extends StatelessWidget {
  const MeowWoofApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '毛语通',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kSeed),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
// 首页骨架（三页导航）
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _page = 0;
  PetProfile _pet = PetProfile();

  @override
  void initState() {
    super.initState();
    ProfileStore.load().then((p) {
      if (mounted) setState(() => _pet = p);
    });
  }

  Future<void> _updatePet(PetProfile p) async {
    setState(() => _pet = p);
    await ProfileStore.save(p);
  }

  /// 场景播放计数（首页快捷卡片按常用度排序）
  Future<void> _recordUsage(String intentId) async {
    final counts = Map.of(_pet.usageCounts);
    counts[intentId] = (counts[intentId] ?? 0) + 1;
    await _updatePet(_pet.copyWith(usageCounts: counts));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _page,
        children: [
          TranslatePage(pet: _pet, onUsage: _recordUsage),
          CallLibraryPage(pet: _pet, onUpdate: _updatePet),
          PetPage(pet: _pet, onUpdate: _updatePet),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        onDestinationSelected: (i) => setState(() => _page = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.translate), label: '翻译'),
          NavigationDestination(
              icon: Icon(Icons.campaign), label: '叫声库'),
          NavigationDestination(icon: Icon(Icons.pets), label: '我的毛孩'),
        ],
      ),
    );
  }
}

// ============================================================
// 页面一：翻译
// ============================================================

enum _ModelStage { loading, ready, failed }

class TranslatePage extends StatefulWidget {
  final PetProfile pet;

  /// 播放场景后回调（首页/快捷卡都走这里），用于统计使用频次
  final void Function(String intentId) onUsage;
  const TranslatePage({super.key, required this.pet, required this.onUsage});

  @override
  State<TranslatePage> createState() => _TranslatePageState();
}

class _TranslatePageState extends State<TranslatePage>
    with SingleTickerProviderStateMixin {
  _ModelStage _stage = _ModelStage.loading;
  String? _error;
  bool _listening = false;
  bool _playing = false;
  String? _playingIntent;
  bool _awaitingFinal = false;
  TranslatorResult? _matched;
  Timer? _finalTimeout;
  Timer? _playingTimer;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      lowerBound: 0.96,
      upperBound: 1.06,
    );
    _boot();
  }

  @override
  void dispose() {
    _finalTimeout?.cancel();
    _playingTimer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    if (!VoiceBridge.hasNative) {
      setState(() {
        _stage = _ModelStage.failed;
        _error = '当前平台没有语音模块，请安装 Android 版 APK 使用完整功能。\n'
            '叫声库与我的毛孩页仍可正常浏览。';
      });
      return;
    }
    try {
      var ok = await VoiceBridge.hasMicPermission();
      if (!ok) ok = await VoiceBridge.requestMicPermission();
      if (!ok) {
        setState(() {
          _stage = _ModelStage.failed;
          _error = '没有麦克风权限。请到系统设置 → 应用 → 毛语通 → 权限，'
              '允许麦克风后重新打开。';
        });
        return;
      }
      VoiceBridge.setHandlers(
        onFinal: (json) => _onFinal(textFromVoskJson(json)),
        onError: (msg) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            _awaitingFinal = false;
            _error = msg;
          });
          _pulse.stop();
        },
      );
      await VoiceBridge.initModel();
      if (mounted) setState(() => _stage = _ModelStage.ready);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _ModelStage.failed;
          _error = '语音模型初始化失败：$e';
        });
      }
    }
  }

  Future<void> _start() async {
    if (_stage != _ModelStage.ready || _listening) return;
    _finalTimeout?.cancel();
    setState(() {
      _listening = true;
      _matched = null;
      _error = null;
      _awaitingFinal = false;
    });
    _pulse.repeat(reverse: true);
    try {
      // 自由听写 + 引擎端关键词匹配。
      // 不用 Vosk 词表语法：中文小模型的分词（"过 来"vs"过来"）无法离线确认，
      // 词表不匹配会导致全部识别失败；自由听写 + 去空格匹配更稳健。
      await VoiceBridge.startListening(null);
    } catch (e) {
      setState(() {
        _listening = false;
        _error = '无法开始识别：$e';
      });
      _pulse.stop();
    }
  }

  Future<void> _stop() async {
    if (!_listening) return;
    _pulse.stop();
    setState(() {
      _listening = false;
      _awaitingFinal = true;
    });
    try {
      await VoiceBridge.stopListening();
    } catch (_) {}
    // 松开后 1.2 秒还没等到最终结果 → 按"没听清"兜底
    _finalTimeout?.cancel();
    _finalTimeout = Timer(const Duration(milliseconds: 1200), () {
      if (_awaitingFinal) _onFinal('');
    });
  }

  Future<void> _onFinal(String text) async {
    if (!_awaitingFinal || !mounted) return;
    _awaitingFinal = false;
    _finalTimeout?.cancel();
    // v1.2.2：不弹识别文字卡片，改为「识别到指令：X，已匹配猫/狗叫」提示条
    final r = IntentMatcher.translate(text);
    setState(() => _matched = r);
    await _play(r.intent.id);
  }

  Future<void> _play(String intentId) async {
    if (!VoiceBridge.hasNative) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('播放需要 Android 版毛语通')),
      );
      return;
    }
    final idx = indexOfIntent(intentId);
    if (idx < 0) return;
    // v1.2.1：固定主文件（不再随机轮换变体），由原生层按意图连播
    final asset = callAsset(widget.pet.species, intentId, idx);
    try {
      final info = await VoiceBridge.playCall(
          asset, widget.pet.playbackRate,
          repeat: repeatCount(intentId));
      final durMs = ((info['durationMs'] as num?)?.toInt() ?? 800) /
          widget.pet.playbackRate;
      setState(() {
        _playing = true;
        _playingIntent = intentId;
      });
      widget.onUsage(intentId); // 使用频次 → 首页快捷排序
      _playingTimer?.cancel();
      _playingTimer =
          Timer(Duration(milliseconds: durMs.toInt() + 300), () {
        if (mounted) {
          setState(() {
            _playing = false;
            _playingIntent = null;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _header(),
          const SizedBox(height: 16),
          _micButton(cs),
          const SizedBox(height: 12),
          Center(
            child: Text(
              _listening
                  ? '正在听……松开立即翻译'
                  : (_stage == _ModelStage.ready
                      ? '按住说话，或点一下开始/停止'
                      : '语音模块未就绪'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          // v1.2.2：不再弹识别文字卡片，只给一行「识别到指令」提示
          if (_listening)
            _hintLine(cs, Icons.hearing, '正在听……松开立即翻译')
          else if (_matched != null) ...[
            if (_matched!.isFallback)
              _hintLine(cs, Icons.chat_bubble_outline, '没听清，先陪它聊两句')
            else
              _hintLine(
                cs,
                Icons.check_circle_outline,
                '识别到指令：${_matched!.intent.name}，'
                '已匹配${widget.pet.species == 'cat' ? '猫' : '狗'}叫',
              ),
          ] else if (_playing && _playingIntent != null) ...[
            _hintLine(
              cs,
              Icons.volume_up,
              '正在播放：${_intentName(_playingIntent!)}',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            _errorCard(cs),
          ],
          const SizedBox(height: 20),
          _quickSection(cs),
        ],
      ),
    );
  }

  String _intentName(String id) {
    final idx = indexOfIntent(id);
    return idx >= 0 ? kIntents[idx].name : id;
  }

  Widget _hintLine(ColorScheme cs, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final pet = widget.pet;
    final speciesLabel = pet.species == 'cat' ? '猫' : '狗';
    return Row(
      children: [
        CircleAvatar(
          radius: 22,
          backgroundImage:
              pet.photoPath != null ? FileImage(File(pet.photoPath!)) : null,
          child: pet.photoPath == null
              ? const Icon(Icons.pets, size: 22)
              : null,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pet.name,
                  style: Theme.of(context).textTheme.titleMedium),
              Text(
                pet.hasVoicePrint
                    ? '$speciesLabel · 音色匹配 ${pet.playbackRate.toStringAsFixed(2)}x'
                    : '$speciesLabel · 未录入叫声（去"我的毛孩"录一段）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _micButton(ColorScheme cs) {
    final ready = _stage == _ModelStage.ready;
    return Center(
      child: GestureDetector(
        onTap: () => _listening ? _stop() : _start(),
        onLongPressStart: (_) => _start(),
        onLongPressEnd: (_) => _stop(),
        child: ScaleTransition(
          scale: _listening
              ? _pulse
              : const AlwaysStoppedAnimation(1.0),
          child: Container(
            width: 148,
            height: 148,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _listening
                  ? cs.primary
                  : (_playing ? cs.primaryContainer : cs.surfaceContainerHighest),
              boxShadow: [
                BoxShadow(
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                  color: cs.primary.withOpacity(_listening ? 0.35 : 0.12),
                ),
              ],
            ),
            child: Icon(
              _listening ? Icons.hearing : Icons.mic,
              size: 56,
              color: _listening
                  ? cs.onPrimary
                  : (ready ? cs.primary : cs.outline),
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorCard(ColorScheme cs) {
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(_error!,
            style: TextStyle(color: cs.onErrorContainer)),
      ),
    );
  }

  /// 首页下半部：横向滑动快捷卡片（常用 3 个）+ 展开更多抽屉
  Widget _quickSection(ColorScheme cs) {
    final quickIds = quickIntentIds(widget.pet, limit: 3);
    final quick = quickIds.map((id) => kIntents[indexOfIntent(id)]).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('不方便说话？直接点场景播放',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            TextButton.icon(
              onPressed: _openDrawer,
              icon: const Icon(Icons.grid_view, size: 18),
              label: const Text('全部场景'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 118,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: quick.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final it = quick[i];
              final playing = _playingIntent == it.id;
              final idx = indexOfIntent(it.id);
              return _quickCard(cs, it, idx, playing);
            },
          ),
        ),
      ],
    );
  }

  Widget _quickCard(ColorScheme cs, IntentCall it, int idx, bool playing) {
    return SizedBox(
      width: 148,
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _play(it.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      playing ? Icons.volume_up : Icons.pets,
                      size: 20,
                      color: playing ? cs.primary : kSeed,
                    ),
                    const Spacer(),
                    if (widget.pet.pinnedIds.contains(it.id))
                      Icon(Icons.push_pin, size: 13, color: cs.outline),
                  ],
                ),
                const Spacer(),
                Text(
                  it.name,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  it.phonetic(widget.pet.species),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openDrawer() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('全部场景',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final it in kIntents)
              ListTile(
                leading: CircleAvatar(
                  radius: 14,
                  child: Text('${indexOfIntent(it.id) + 1}',
                      style: const TextStyle(fontSize: 12)),
                ),
                title: Text(it.name),
                subtitle: Text(
                  it.phonetic(widget.pet.species),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kSeed),
                ),
                trailing: widget.pet.pinnedIds.contains(it.id)
                    ? const Icon(Icons.push_pin, size: 18)
                    : null,
                onTap: () => Navigator.pop(context, it.id),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _play(picked);
  }
}

// ============================================================
// 页面二：叫声库（10 个预设，猫狗两套，带用途说明）
// ============================================================

class CallLibraryPage extends StatefulWidget {
  final PetProfile pet;

  /// 置顶变更回调（首页快捷卡片同步）
  final Future<void> Function(PetProfile)? onUpdate;
  const CallLibraryPage({super.key, required this.pet, this.onUpdate});

  @override
  State<CallLibraryPage> createState() => _CallLibraryPageState();
}

class _CallLibraryPageState extends State<CallLibraryPage> {
  late String _species = widget.pet.species;
  String? _playingId;

  /// 已展开的科普卡片（默认折叠，只留名字+播放）
  final Set<String> _expanded = {};

  @override
  void didUpdateWidget(covariant CallLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // “我的毛孩”页改了物种时同步过来
    if (widget.pet.species != oldWidget.pet.species) {
      _species = widget.pet.species;
    }
  }

  Future<void> _play(IntentCall it, int idx) async {
    if (!VoiceBridge.hasNative) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('播放需要 Android 版毛语通')),
      );
      return;
    }
    setState(() => _playingId = it.id);
    // v1.2.1：固定主文件（不再随机轮换变体），由原生层按意图连播
    final asset = callAsset(_species, it.id, idx);
    try {
      final info = await VoiceBridge.playCall(
          asset, widget.pet.playbackRate,
          repeat: repeatCount(it.id));
      final durMs = ((info['durationMs'] as num?)?.toInt() ?? 800) /
          widget.pet.playbackRate;
      Future.delayed(Duration(milliseconds: durMs.toInt() + 300), () {
        if (mounted && _playingId == it.id) {
          setState(() => _playingId = null);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _playingId = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败：$e')),
        );
      }
    }
  }

  /// 置顶/取消置顶：置顶的场景会出现在首页快捷卡片最前
  Future<void> _togglePin(String id) async {
    final update = widget.onUpdate;
    if (update == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前版本不支持置顶')),
      );
      return;
    }
    final pinned = List.of(widget.pet.pinnedIds);
    if (pinned.contains(id)) {
      pinned.remove(id);
    } else {
      pinned.insert(0, id);
      if (pinned.length > 3) pinned.removeRange(3, pinned.length);
    }
    await update(widget.pet.copyWith(pinnedIds: pinned));
    if (mounted) setState(() {});
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
                Text('10 个预设叫声',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '每个意思固定一种叫声——点卡片展开科普，'
                  '图钉把最常用的固定到首页。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '诚实说明：猫狗没有人类式语言，这不是"真翻译"；'
                            '是基于行为学研究的固定声音信号 + 条件反射训练法。'
                            '素材源自 Wikimedia Commons 与 Freesound（见 NOTICE）。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'cat', label: Text('猫语')),
                    ButtonSegment(value: 'dog', label: Text('狗语')),
                  ],
                  selected: {_species},
                  onSelectionChanged: (s) =>
                      setState(() => _species = s.first),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: kIntents.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final it = kIntents[i];
                final playing = _playingId == it.id;
                final expanded = _expanded.contains(it.id);
                final pinned = widget.pet.pinnedIds.contains(it.id);
                return Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => expanded
                        ? _expanded.remove(it.id)
                        : _expanded.add(it.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 14,
                                child: Text('${i + 1}',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(it.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                            fontWeight: FontWeight.w700)),
                              ),
                              // 设为首页快捷：置顶到首页快捷卡片最前
                              IconButton.filledTonal(
                                visualDensity: VisualDensity.compact,
                                tooltip: pinned
                                    ? '取消首页快捷'
                                    : '设为首页快捷',
                                onPressed: () => _togglePin(it.id),
                                icon: Icon(
                                  pinned
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                  size: 20,
                                ),
                              ),
                              IconButton.filledTonal(
                                onPressed: () => _play(it, i),
                                icon: Icon(playing
                                    ? Icons.volume_up
                                    : Icons.play_arrow),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            it.phonetic(_species),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: kSeed),
                          ),
                          if (expanded) ...[
                            const SizedBox(height: 6),
                            Text('对它说：${it.meaning}',
                                style:
                                    Theme.of(context).textTheme.bodyMedium),
                            const SizedBox(height: 4),
                            Text('作用：${it.purpose}',
                                style:
                                    Theme.of(context).textTheme.bodySmall),
                            const SizedBox(height: 4),
                            Text('小贴士：${it.tip}',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                        fontStyle: FontStyle.italic)),
                          ] else ...[
                            const SizedBox(height: 2),
                            Text(
                              '对它说：${it.meaning}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.outline),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// 页面三：我的毛孩（头像 / 资料 / 录音音高 / 音色匹配）
// ============================================================

class PetPage extends StatefulWidget {
  final PetProfile pet;
  final Future<void> Function(PetProfile) onUpdate;
  const PetPage({super.key, required this.pet, required this.onUpdate});

  @override
  State<PetPage> createState() => _PetPageState();
}

class _PetPageState extends State<PetPage> {
  late final TextEditingController _nameCtl =
      TextEditingController(text: widget.pet.name);
  bool _recording = false;
  bool _analyzing = false;
  int _recSecs = 0;
  Timer? _tick;
  Map<Object?, Object?>? _lastRec;
  String _nativeVersion = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void didUpdateWidget(covariant PetPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宠物资料异步加载完成或被其他页面修改时，同步名字输入框
    if (widget.pet.name != oldWidget.pet.name &&
        _nameCtl.text != widget.pet.name) {
      _nameCtl.text = widget.pet.name;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    try {
      final v = await VoiceBridge.buildVersion();
      if (mounted) setState(() => _nativeVersion = v);
    } catch (_) {}
  }

  Future<void> _pickPhoto(ImageSource src) async {
    try {
      final picker = ImagePicker();
      final x = await picker.pickImage(source: src, imageQuality: 85);
      if (x == null) return;
      final saved = await ProfileStore.importPhoto(x.path);
      if (saved != null) {
        await widget.onUpdate(widget.pet.copyWith(photoPath: saved));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('照片获取失败：$e')),
        );
      }
    }
  }

  Future<void> _startRec() async {
    try {
      await VoiceBridge.startPetRecording();
      setState(() {
        _recording = true;
        _recSecs = 0;
        _lastRec = null;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        setState(() => _recSecs++);
        if (_recSecs >= 20) _stopRec(); // 最长 20 秒自动停
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法开始录音：$e')),
        );
      }
    }
  }

  Future<void> _stopRec() async {
    _tick?.cancel();
    if (!_recording) return;
    setState(() {
      _recording = false;
      _analyzing = true;
    });
    try {
      final r = await VoiceBridge.stopPetRecording();
      final f0 = (r['f0'] as num?)?.toDouble() ?? 0;
      await widget.onUpdate(widget.pet.copyWith(pitchHz: f0));
      setState(() {
        _lastRec = r;
        _analyzing = false;
      });
    } catch (e) {
      setState(() => _analyzing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  Future<void> _replayRecording() async {
    final path = _lastRec?['path'] as String?;
    if (path == null) return;
    try {
      await VoiceBridge.playCall(path, 1.0);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('回放失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pet = widget.pet;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundImage: pet.photoPath != null
                      ? FileImage(File(pet.photoPath!))
                      : null,
                  child: pet.photoPath == null
                      ? const Icon(Icons.pets, size: 48)
                      : null,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: PopupMenuButton<ImageSource>(
                    icon: CircleAvatar(
                      radius: 16,
                      backgroundColor:
                          Theme.of(context).colorScheme.primary,
                      child: Icon(Icons.photo_camera,
                          size: 16,
                          color: Theme.of(context).colorScheme.onPrimary),
                    ),
                    onSelected: _pickPhoto,
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: ImageSource.camera, child: Text('拍照')),
                      PopupMenuItem(
                          value: ImageSource.gallery, child: Text('从相册选')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtl,
            decoration: const InputDecoration(
              labelText: '名字',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) {
              final name = v.trim();
              if (name.isEmpty || name == widget.pet.name) return;
              widget.onUpdate(widget.pet.copyWith(name: name));
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'cat', label: Text('猫'), icon: Icon(Icons.cruelty_free)),
              ButtonSegment(value: 'dog', label: Text('狗'), icon: Icon(Icons.pets)),
            ],
            selected: {pet.species},
            onSelectionChanged: (s) =>
                widget.onUpdate(widget.pet.copyWith(species: s.first)),
          ),
          const SizedBox(height: 20),
          _voicePrintCard(context, pet),
          const SizedBox(height: 20),
          Center(
            child: Text(
              _nativeVersion.isEmpty
                  ? '毛语通 1.2.2'
                  : '毛语通 1.2.2 · 原生端 $_nativeVersion',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _voicePrintCard(BuildContext context, PetProfile pet) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('录它的叫声 · 音色匹配',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              pet.hasVoicePrint
                  ? '已录入：基频 ${pet.pitchHz.toStringAsFixed(0)} Hz，'
                      '播放叫声时按 ${pet.playbackRate.toStringAsFixed(2)}x 变速变调，'
                      '更接近它的音色。'
                  : '录 3~5 秒它最典型的叫声，App 会分析它的音高，'
                      '之后播放所有叫声时自动向它的音色靠拢。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed:
                      _analyzing ? null : (_recording ? _stopRec : _startRec),
                  icon: Icon(_recording ? Icons.stop : Icons.mic),
                  label: Text(_recording
                      ? '停止（$_recSecs s）'
                      : (_analyzing ? '分析中…' : '开始录音')),
                ),
                const SizedBox(width: 10),
                if (_lastRec != null)
                  OutlinedButton.icon(
                    onPressed: _replayRecording,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('回放'),
                  ),
              ],
            ),
            // 录音进度条：0~20 秒，走到头自动停
            if (_recording) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _recSecs / 20,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$_recSecs / 20 s',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            if (_analyzing) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 6),
            ],
            if (_lastRec != null) ...[
              const SizedBox(height: 10),
              Text(
                '本次分析：时长 ${((_lastRec!['durationMs'] as num?)?.toInt() ?? 0)} ms，'
                '基频 ${((_lastRec!['f0'] as num?)?.toDouble() ?? 0).toStringAsFixed(0)} Hz，'
                '有声占比 ${(((_lastRec!['voicedRatio'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (((_lastRec!['f0'] as num?)?.toDouble() ?? 0) == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '没有测到清晰的音高——离它近一点，等它叫的时候再录。',
                    style: TextStyle(color: cs.error),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
