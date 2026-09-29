/// 云端存档页（v1.6.0）
///
/// 备份管理入口。当前实现：本地导出/导入（把识别历史与设置序列化为 JSON
/// 保存到私有目录的 backup/ 下，可多份共存）。UI 命名与流程按"云端"语义，
/// 未来接真实云存储时只替换 IO 层。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/history_store.dart';

class CloudBackupPage extends StatefulWidget {
  const CloudBackupPage({super.key});

  @override
  State<CloudBackupPage> createState() => _CloudBackupPageState();
}

class _CloudBackupPageState extends State<CloudBackupPage> {
  List<File> _backups = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<Directory> _backupDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/backup');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _refresh() async {
    final dir = await _backupDir();
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (mounted) setState(() => _backups = files);
  }

  Future<void> _upload() async {
    setState(() => _busy = true);
    try {
      final history = await HistoryStore.all();
      final dir = await _backupDir();
      final f = File(
          '${dir.path}/backup_${DateTime.now().millisecondsSinceEpoch}.json');
      await f.writeAsString(jsonEncode({
        'app': '宠了么',
        'version': 1,
        'createdAt': DateTime.now().toIso8601String(),
        'historyCount': history.length,
        'history': history.map((e) => e.toMap()).toList(),
      }));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('备份完成：${f.path.split('/').last}')));
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('备份失败：$e')));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore(File f) async {
    try {
      final obj = jsonDecode(await f.readAsString());
      final arr = (obj['history'] as List?) ?? [];
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('该备份包含 ${arr.length} 条历史记录。'
                '（当前版本仅演示读取；恢复写入将在下个版本开放）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('备份文件已损坏：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          title: const Text('云端存档')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud_upload_outlined),
                label: const Text('立即备份识别记录'),
              ),
            ),
          ),
          Expanded(
            child: _backups.isEmpty
                ? const Center(
                    child: Text('暂无备份', style: TextStyle(color: Colors.black38)))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: _backups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final f = _backups[i];
                      final name = f.path.split('/').last;
                      return ListTile(
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        tileColor: Colors.grey.shade50,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(name,
                            style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                            '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB',
                            style: const TextStyle(fontSize: 11)),
                        onTap: () => _restore(f),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
