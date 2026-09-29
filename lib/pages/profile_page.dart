/// 我的主页（v1.6.0）
/// 个人资料（头像/名字/物种）+ 首页背景自定义设置入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import 'dart:io';

import '../services/launcher_store.dart';
import '../services/profile_store.dart';

class ProfilePage extends StatefulWidget {
  final PetProfile pet;
  final Future<void> Function(PetProfile)? onUpdate;
  const ProfilePage({super.key, required this.pet, this.onUpdate});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _nameCtl =
      TextEditingController(text: widget.pet.name);
  LauncherSettings _settings = LauncherSettings();

  @override
  void initState() {
    super.initState();
    LauncherStore.load().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  Future<void> _saveLauncher() async {
    await LauncherStore.save(_settings);
    if (mounted) setState(() {});
  }

  Future<void> _pickAvatar(ImageSource src) async {
    try {
      final x =
          await ImagePicker().pickImage(source: src, imageQuality: 85);
      if (x == null) return;
      final saved = await ProfileStore.importPhoto(x.path);
      if (saved != null) {
        final u1 = widget.onUpdate;
        if (u1 != null) await u1(widget.pet.copyWith(photoPath: saved));
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.code == 'photo_access_denied' ||
                    e.code == 'camera_access_denied'
                ? '权限被拒绝：请到系统设置 → 应用 → 宠了么 → 权限，允许后重试'
                : '照片获取失败：${e.message ?? e.code}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('照片获取失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pet = widget.pet;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          title: const Text('我的主页')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---- 个人资料 ----
          Row(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 34,
                    backgroundImage: pet.photoPath != null
                        ? FileImage(File(pet.photoPath!))
                        : null,
                    child: pet.photoPath == null
                        ? const Icon(Icons.pets, size: 32)
                        : null,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () async {
                        final src =
                            await showSrcSheet(context);
                        if (src != null) _pickAvatar(src);
                      },
                      child: CircleAvatar(
                        radius: 12,
                        backgroundColor:
                            Theme.of(context).colorScheme.primary,
                        child: const Icon(Icons.photo_camera,
                            size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _nameCtl,
                  decoration: const InputDecoration(
                    labelText: '名字',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (v) {
                    final name = v.trim();
                    if (name.isEmpty || name == pet.name) return;
                    final u = widget.onUpdate;
                    if (u != null) u(widget.pet.copyWith(name: name));
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'cat', label: Text('猫'), icon: Icon(Icons.cruelty_free)),
              ButtonSegment(value: 'dog', label: Text('狗'), icon: Icon(Icons.pets)),
            ],
            selected: {pet.species},
            onSelectionChanged: (s) {
              final u = widget.onUpdate;
              if (u != null) u(widget.pet.copyWith(species: s.first));
            },
          ),
          const SizedBox(height: 20),

          // ---- 首页背景设置 ----
          Card(
            color: Colors.grey.shade50,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('首页背景',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 4),
                  const Text('仅首页生效，其他页面保持白底',
                      style: TextStyle(fontSize: 11, color: Colors.black38)),
                  const SizedBox(height: 12),
                  // 5 套模板
                  Row(
                    children: [
                      for (var i = 0; i < 5; i++)
                        GestureDetector(
                          onTap: () {
                            setState(() => _settings.backgroundType = i);
                            _saveLauncher();
                          },
                          child: Container(
                            width: 52,
                            height: 52,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: presetGradient(i),
                              ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                width: _settings.backgroundType == i ? 2.5 : 0.5,
                                color: _settings.backgroundType == i
                                    ? Colors.orange.shade700
                                    : Colors.black12,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _pickCustomBg,
                          icon: const Icon(Icons.wallpaper, size: 18),
                          label: const Text('相册自定义',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                  ),
                  // 自定义背景的模糊/透明度调节
                  if (_settings.backgroundType == -1) ...[
                    const SizedBox(height: 12),
                    Text('高斯模糊：${_settings.blurSigma.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 12)),
                    Slider(
                      min: 0,
                      max: 30,
                      value: _settings.blurSigma,
                      onChanged: (v) =>
                          setState(() => _settings.blurSigma = v),
                      onChangeEnd: (_) => _saveLauncher(),
                    ),
                    Text(
                        '遮罩浓度：${(_settings.overlayOpacity * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(fontSize: 12)),
                    Slider(
                      min: 0,
                      max: 0.7,
                      value: _settings.overlayOpacity,
                      onChanged: (v) =>
                          setState(() => _settings.overlayOpacity = v),
                      onChangeEnd: (_) => _saveLauncher(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomBg() async {
    try {
      final x = await ImagePicker()
          .pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (x == null) return;
      final saved = await importLauncherBackground(x.path);
      if (saved != null) {
        setState(() {
          _settings
            ..backgroundType = -1
            ..customBgPath = saved;
        });
        await _saveLauncher();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('已设为首页背景'), duration: Duration(seconds: 1)));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('背景图获取失败：$e')));
      }
    }
  }

  static Future<ImageSource?> showSrcSheet(BuildContext context) {
    return showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(sheetCtx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo),
              title: const Text('从相册选'),
              onTap: () => Navigator.pop(sheetCtx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }
}
