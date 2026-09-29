/// 录音识别页（v1.6.0 独立页）
/// 大录音按钮 + 录音历史（沿用 RecordingStore FIFO 10 条）+ 回放。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/profile_store.dart';
import '../services/recording_store.dart';
import '../services/voice_bridge.dart';

class RecordPage extends StatefulWidget {
  final PetProfile pet;
  const RecordPage({super.key, required this.pet});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  bool _recording = false;
  bool _analyzing = false;
  int _recSecs = 0;
  Timer? _tick;
  List<RecordingItem> _items = [];

  @override
  void initState() {
    super.initState();
    RecordingStore.all().then((l) {
      if (mounted) setState(() => _items = l);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      await VoiceBridge.startPetRecording();
      setState(() {
        _recording = true;
        _recSecs = 0;
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (t) {
        setState(() => _recSecs++);
        if (_recSecs >= 20) _stop();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法开始录音：$e')));
      }
    }
  }

  Future<void> _stop() async {
    _tick?.cancel();
    if (!_recording) return;
    setState(() {
      _recording = false;
      _analyzing = true;
    });
    try {
      final r = await VoiceBridge.stopPetRecording();
      final f0 = (r['f0'] as num?)?.toDouble() ?? 0;
      final evicted = await RecordingStore.add(RecordingItem(
        path: (r['path'] as String?) ?? '',
        durationMs: (r['durationMs'] as num?)?.toInt() ?? 0,
        f0: f0,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
      final items = await RecordingStore.all();
      if (mounted) {
        setState(() {
          _analyzing = false;
          _items = items;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '已保存。基频 ${f0.toStringAsFixed(0)} Hz${evicted != null ? '（最早一条已清理）' : ''}'),
          duration: const Duration(seconds: 2),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _analyzing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          title: const Text('录音识别')),
      body: Column(
        children: [
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => _recording ? _stop() : _start(),
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _recording ? cs.primary : Colors.grey.shade100,
              ),
              child: Icon(_recording ? Icons.stop : Icons.mic,
                  size: 52,
                  color: _recording ? cs.onPrimary : cs.primary),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _recording
                ? '正在录音 $_recSecs / 20 s'
                : (_analyzing ? '分析中…' : '点击录制宠物声音'),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_recording) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: LinearProgressIndicator(
                  value: _recSecs / 20, minHeight: 6),
            ),
          ],
          const Divider(height: 32),
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('录音历史（${10} 条上限）',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const Center(
                    child: Text('暂无录音', style: TextStyle(color: Colors.black38)))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, i) {
                      final it = _items[i];
                      return ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        tileColor: Colors.grey.shade50,
                        leading: const Icon(Icons.graphic_eq),
                        title: Text(
                            '${DateTime.fromMillisecondsSinceEpoch(it.createdAtMs).toString().substring(5, 16)} · ${(it.durationMs / 1000).toStringAsFixed(1)}s',
                            style: const TextStyle(fontSize: 13)),
                        subtitle: it.f0 > 0
                            ? Text('基频 ${it.f0.toStringAsFixed(0)} Hz',
                                style: const TextStyle(fontSize: 11))
                            : null,
                        trailing: IconButton(
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () async {
                            try {
                              await VoiceBridge.playCall(it.path, 1.0, repeat: 1);
                            } catch (_) {}
                          },
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
