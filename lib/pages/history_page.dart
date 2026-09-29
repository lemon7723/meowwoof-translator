/// 识别历史页（v1.6.0）
/// 汇总体态识别与录音识别记录（本机最多 50 条，FIFO）。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../services/history_store.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<HistoryItem> _items = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final items = await HistoryStore.all();
    if (mounted) setState(() => _items = items);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('识别历史'),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清空历史'),
                    content: const Text('将删除全部识别记录，此操作不可撤销。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('清空')),
                    ],
                  ),
                );
                if (ok == true) {
                  await HistoryStore.clear();
                  _refresh();
                }
              },
              child: const Text('清空'),
            ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Text('还没有识别记录', style: TextStyle(color: Colors.black38)))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final it = _items[i];
                final isPose = it.kind == 'pose';
                final time = DateTime.fromMillisecondsSinceEpoch(it.createdAtMs);
                final media = File(it.mediaPath);
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 缩略图/图标
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: isPose && media.existsSync()
                            ? Image.file(media, fit: BoxFit.cover)
                            : Icon(
                                isPose ? Icons.pets : Icons.mic_none,
                                color: Colors.black26,
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  isPose ? '体态识别' : '录音识别',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                    time.toString().substring(5, 16),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.black38)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${it.species == 'cat' ? '猫' : '狗'} · ${it.emotion}'
                              '${it.conf != null ? '（置信 ${(it.conf! * 100).toStringAsFixed(0)}%）' : ''}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            if (it.detail.isNotEmpty)
                              Text(it.detail,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.black45),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
