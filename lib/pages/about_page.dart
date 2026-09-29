/// 关于 APP 页（v1.6.0）
library;

import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          title: const Text('关于宠了么')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 8),
          Center(
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(Icons.pets,
                      size: 40, color: Colors.orange.shade700),
                ),
                const SizedBox(height: 12),
                const Text('宠了么',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const Text('v1.6.0', style: TextStyle(color: Colors.black38)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _card(context, '功能说明', [
            '体态解读：上传宠物照片，AI 分析肢体姿态与情绪状态。',
            '猫/狗叫声库：基于行为学研究的预设叫声，配合奖励可作训练信号。',
            '录音识别：录制宠物叫声分析基频，做音色匹配。',
            '识别历史：自动汇总体态与录音识别记录（本机保存，最多 50 条）。',
          ]),
          const SizedBox(height: 12),
          _card(context, '隐私说明', [
            '所有识别均在设备本地完成（语音识别 Vosk、体态 RTMPose-Animal）。',
            '照片与录音仅保存在应用私有目录，不会上传任何服务器。',
            '「云端存档」为本地备份管理入口，当前版本不产生真实网络上传。',
          ]),
          const SizedBox(height: 12),
          _card(context, '开源致谢', [
            'RTMPose-Animal（AP-10K）— Apache-2.0 License',
            'Vosk 离线语音识别 — Apache-2.0 License',
            '叫声素材：Wikimedia Commons / Freesound（CC0/CC BY/CC BY-SA，见应用内 NOTICE）',
          ]),
          const SizedBox(height: 24),
          const Center(
            child: Text('宠了么仅为宠物趣味娱乐工具，不能替代兽医专业诊断。',
                style: TextStyle(fontSize: 12, color: Colors.black38)),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, String title, List<String> lines) {
    return Card(
      color: Colors.grey.shade50,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $l',
                    style: const TextStyle(fontSize: 13.5, height: 1.5)),
              ),
          ],
        ),
      ),
    );
  }
}
