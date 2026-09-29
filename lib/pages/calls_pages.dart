/// 猫叫声库（v1.6.0 独立页）
/// 白底极简：10 个意图的猫语叫声列表，点击播放（连播规则沿用）。
library;

import 'package:flutter/material.dart';

import '../data/call_library.dart';
import '../services/voice_bridge.dart';
import '../services/profile_store.dart';

class CatCallsPage extends StatelessWidget {
  final PetProfile pet;
  const CatCallsPage({super.key, required this.pet});

  @override
  Widget build(BuildContext context) {
    return _CallsListPage(species: 'cat', title: '猫叫声库', pet: pet);
  }
}

class DogCallsPage extends StatelessWidget {
  final PetProfile pet;
  const DogCallsPage({super.key, required this.pet});

  @override
  Widget build(BuildContext context) {
    return _CallsListPage(species: 'dog', title: '狗叫声库', pet: pet);
  }
}

class _CallsListPage extends StatefulWidget {
  final String species;
  final String title;
  final PetProfile pet;
  const _CallsListPage(
      {required this.species, required this.title, required this.pet});

  @override
  State<_CallsListPage> createState() => _CallsListPageState();
}

class _CallsListPageState extends State<_CallsListPage> {
  String? _playingId;

  Future<void> _play(IntentCall it, int idx) async {
    if (!VoiceBridge.hasNative) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('播放需要 Android 版宠了么')),
      );
      return;
    }
    setState(() => _playingId = it.id);
    try {
      final info = await VoiceBridge.playCall(
          callAsset(widget.species, it.id, idx),
          widget.pet.playbackRate,
          repeat: repeatCount(it.id));
      final durMs = ((info['durationMs'] as num?)?.toInt() ?? 800) /
          widget.pet.playbackRate;
      await Future.delayed(Duration(milliseconds: durMs.toInt() + 300));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('播放失败：$e')));
      }
    }
    if (mounted) setState(() => _playingId = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(widget.title),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: kIntents.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final it = kIntents[i];
          final playing = _playingId == it.id;
          return ListTile(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            tileColor: Colors.grey.shade50,
            leading: CircleAvatar(
              radius: 14,
              child: Text('${i + 1}', style: const TextStyle(fontSize: 12)),
            ),
            title: Text(it.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              it.phonetic(widget.species),
              style: const TextStyle(color: Color(0xFFE8722A)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton.filledTonal(
              onPressed: () => _play(it, i),
              icon:
                  Icon(playing ? Icons.volume_up : Icons.play_arrow),
            ),
          );
        },
      ),
    );
  }
}
