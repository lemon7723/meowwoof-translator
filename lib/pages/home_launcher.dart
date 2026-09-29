/// 首页 Launcher（v1.6.0）—— 仿 iOS 主屏宫格
///
/// 结构：
///  - 顶部导航：左头像 / 中「宠了么」/ 右⚙设置（进「我的主页」）
///  - 宫格：体态解读大图标固定 C 位（第一行第一个），其余 7 个小图标
///    可长按拖拽换位（抖动动画 + 网格吸附），布局持久化
///  - 背景：5 套内置模板 / 相册自定义（高斯模糊 + 透明度可调），仅首页生效
///  - 点击图标 → Navigator.push 对应独立二级页（白底极简）
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/launcher_store.dart';
import '../services/profile_store.dart';
import 'about_page.dart';
import 'calls_pages.dart';
import 'cloud_backup_page.dart';
import 'history_page.dart';
import 'pose_page.dart';
import 'profile_page.dart';
import 'record_page.dart';

/// 小图标元数据
class LauncherTile {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  const LauncherTile(this.id, this.name, this.desc, this.icon);
}

const List<LauncherTile> kSmallTiles = [
  LauncherTile('cat', '猫叫声库', '各类猫咪叫声，一键播放', Icons.pets),
  LauncherTile('dog', '狗叫声库', '多种狗狗叫声，试听参考', Icons.hearing),
  LauncherTile('mic', '录音识别', '录制宠物声音，分析情绪', Icons.mic_none),
  LauncherTile('history', '识别历史', '查看全部体态、声音记录', Icons.history_edu),
  LauncherTile('cloud', '云端存档', '识别记录云端备份保存', Icons.cloud_outlined),
  LauncherTile('profile', '我的主页', '个人资料、首页背景设置', Icons.person_outline),
  LauncherTile('about', '关于 APP', '版本信息与功能说明', Icons.info_outline),
];

Widget? _pageFor(String id, PetProfile pet,
    {Future<void> Function(PetProfile)? onUpdate}) {
  switch (id) {
    case 'pose':
      return PosePage(pet: pet);
    case 'cat':
      return CatCallsPage(pet: pet);
    case 'dog':
      return DogCallsPage(pet: pet);
    case 'mic':
      return RecordPage(pet: pet);
    case 'history':
      return const HistoryPage();
    case 'cloud':
      return const CloudBackupPage();
    case 'profile':
      return ProfilePage(pet: pet, onUpdate: onUpdate);
    case 'about':
      return const AboutPage();
  }
  return null;
}

class HomeLauncher extends StatefulWidget {
  final PetProfile pet;
  final Future<void> Function(PetProfile) onUpdate;
  const HomeLauncher({super.key, required this.pet, required this.onUpdate});

  @override
  State<HomeLauncher> createState() => _HomeLauncherState();
}

class _HomeLauncherState extends State<HomeLauncher>
    with SingleTickerProviderStateMixin {
  LauncherSettings _settings = LauncherSettings();
  bool _editMode = false; // 长按进入的抖动编辑模式
  String? _dragId; // 正在拖拽的图标
  late final AnimationController _wobble;

  @override
  void initState() {
    super.initState();
    _wobble = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 240));
    _wobble.repeat(reverse: true); // 编辑模式下持续抖动
    LauncherStore.load().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  @override
  void dispose() {
    _wobble.dispose();
    super.dispose();
  }

  Future<void> _persist() => LauncherStore.save(_settings);

  Future<void> _open(String id) async {
    if (_editMode) return; // 编辑模式点击不跳转
    final page = _pageFor(id, widget.pet, onUpdate: widget.onUpdate);
    if (page == null) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {}); // 返回后刷新（历史/资料可能变化）
  }

  /// 拖拽换位：与目标槽位的小图标交换顺序
  void _reorder(String dragId, String targetId) {
    if (dragId == targetId) return;
    final list = List.of(_settings.order);
    final from = list.indexOf(dragId);
    final to = list.indexOf(targetId);
    if (from < 0 || to < 0) return;
    list.removeAt(from);
    list.insert(to, dragId);
    setState(() => _settings.order = list);
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = _settings.customBgPath != null &&
            File(_settings.customBgPath!).existsSync()
        ? _CustomBg(
            path: _settings.customBgPath!,
            blur: _settings.blurSigma,
            overlay: _settings.overlayOpacity)
        : _PresetBg(colors: kPresetBackgrounds[_settings.backgroundType.clamp(0, 4)]);

    return Stack(
      fit: StackFit.expand,
      children: [
        bg,
        SafeArea(
          child: Column(
            children: [
              _navBar(cs),
              Expanded(
                child: _editMode
                    ? _gridEditable(cs)
                    : SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: _grid(cs),
                      ),
              ),
              if (_editMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: FilledButton.tonal(
                    onPressed: () {
                      setState(() => _editMode = false);
                      _persist();
                    },
                    child: const Text('完成'),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- 顶部导航 ----------------

  Widget _navBar(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          // 左：头像（点按进入我的主页）
          GestureDetector(
            onTap: () => _open('profile'),
            child: CircleAvatar(
              radius: 20,
              backgroundImage: widget.pet.photoPath != null
                  ? FileImage(File(widget.pet.photoPath!))
                  : null,
              child: widget.pet.photoPath == null
                  ? const Icon(Icons.pets, size: 20)
                  : null,
            ),
          ),
          const Spacer(),
          Text('宠了么',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          // 右：快速设置 ⚙ → 我的主页（背景设置所在页）
          IconButton(
            tooltip: '设置',
            icon: Icon(Icons.settings_outlined, color: cs.outline),
            onPressed: () => _open('profile'),
          ),
        ],
      ),
    );
  }

  // ---------------- 宫格 ----------------

  /// 编辑/浏览共用网格：pose 大图标固定第 1 位，7 个小图标按 order 排列
  Widget _gridCell(String id) {
    if (id == 'pose') {
      return _TileView(
        id: 'pose',
        name: '体态解读',
        desc: '拍照识别宠物肢体与情绪',
        icon: Icons.assistant_navigation,
        big: true,
        editMode: _editMode,
        wobble: _wobble,
        onTap: () => _open('pose'),
        onLongPress: null, // 大图标不允许进入拖拽
      );
    }
    final meta = kSmallTiles.firstWhere((t) => t.id == id);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data == id ? false : true,
      onAcceptWithDetails: (details) => _reorder(details.data, id),
      builder: (context, _, __) => Draggable<String>(
        data: id,
        feedback: _TileView(
          id: id,
          name: meta.name,
          desc: meta.desc,
          icon: meta.icon,
          big: false,
          editMode: false,
          wobble: null,
          dragging: true,
        ),
        childWhenDragging: const SizedBox(width: 96, height: 108),
        onDragStarted: () => setState(() => _dragId = id),
        onDragEnd: (_) => setState(() => _dragId = null),
        child: _TileView(
          id: id,
          name: meta.name,
          desc: meta.desc,
          icon: meta.icon,
          big: false,
          editMode: _editMode,
          wobble: _wobble,
          dragging: _dragId == id,
          onTap: () => _open(id),
          onLongPress: _editMode
              ? null
              : () {
                  // 长按任意小图标进入编辑模式（带触觉反馈）
                  HapticFeedback.mediumImpact();
                  setState(() => _editMode = true);
                },
        ),
      ),
    );
  }

  Widget _grid(ColorScheme cs) {
    final small = _settings.order;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _gridCell('pose'), // C 位
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _gridCell(small[0])),
                        const SizedBox(width: 10),
                        Expanded(child: _gridCell(small[1])),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _gridCell(small[2])),
                        const SizedBox(width: 10),
                        Expanded(child: _gridCell(small[3])),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _gridCell(small[4])),
              const SizedBox(width: 10),
              Expanded(child: _gridCell(small[5])),
              const SizedBox(width: 10),
              Expanded(child: _gridCell(small[6])),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// 编辑模式：布局同一张网格，但全部可拖拽（拖拽手柄直接生效）
  Widget _gridEditable(ColorScheme cs) => _grid(cs);
}

// ============================================================
// 图标视图（大/小两档，编辑抖动，两行文字）
// ============================================================

class _TileView extends StatelessWidget {
  final String id;
  final String name;
  final String desc;
  final IconData icon;
  final bool big;
  final bool editMode;
  final AnimationController? wobble;
  final bool dragging;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _TileView({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.big,
    required this.editMode,
    required this.wobble,
    this.dragging = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = big ? 96.0 : 64.0;
    final radius = big ? 24.0 : 16.0; // 底板圆角

    Widget plate = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surface.withOpacity(0.92), // 半透明遮罩保证可读
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Icon(icon, size: size * 0.46, color: kLauncherInk),
      ),
    );

    // 编辑模式：轻微放大 + 抖动
    if (editMode && wobble != null) {
      final angle = math.sin(wobble!.value * math.pi * 2) * 0.03;
      plate = Transform.rotate(
        angle: angle,
        child: Transform.scale(scale: 1.05, child: plate),
      );
    }
    if (dragging) {
      plate = Opacity(opacity: 0.45, child: plate);
    }

    final tile = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        plate,
        SizedBox(height: big ? 8.0 : 6.0),
        SizedBox(
          width: big ? 110 : 96,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: big ? 14 : 12,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          width: big ? 116 : 98,
          child: Text(
            desc,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: big ? 10.5 : 9.5,
              height: 1.25,
              color: Colors.black38,
            ),
          ),
        ),
      ],
    );

    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: tile,
      ),
    );
  }
}

/// 图标墨色（统一线性描边色，iOS 灰黑）
const Color kLauncherInk = Color(0xFF3A3A3C);

// ============================================================
// 背景
// ============================================================

/// 内置模板：柔和渐变
class _PresetBg extends StatelessWidget {
  final List<Color> colors;
  const _PresetBg({required this.colors});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }
}

/// 自定义背景：高斯模糊 + 半透明遮罩
class _CustomBg extends StatelessWidget {
  final String path;
  final double blur;
  final double overlay;
  const _CustomBg(
      {required this.path, required this.blur, required this.overlay});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: 1080, // 降采样省内存
        ),
        BackdropFilter(
          filter: ui.ImageFilter.blur(
              sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
          child: Container(color: Colors.white.withOpacity(overlay)),
        ),
      ],
    );
  }
}
