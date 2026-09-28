import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:meowwoof_translator/data/call_library.dart';
import 'package:meowwoof_translator/logic/translator_engine.dart';
import 'package:meowwoof_translator/services/profile_store.dart';
import 'package:meowwoof_translator/services/voice_bridge.dart';

void main() {  // ============================================================
  // 叫声库完整性
  // ============================================================
  group('call library', () {
    test('正好 10 个预设意图', () {
      expect(kIntents.length, 10);
    });

    test('意图 id 唯一且非空', () {
      final ids = kIntents.map((e) => e.id).toSet();
      expect(ids.length, 10);
      expect(ids.every((e) => e.isNotEmpty), isTrue);
    });

    test('每个意图的猫狗拟声、用途说明齐全', () {
      for (final it in kIntents) {
        expect(it.name, isNotEmpty, reason: '${it.id} 缺 name');
        expect(it.catPhonetic, isNotEmpty, reason: '${it.id} 缺猫语拟声');
        expect(it.dogPhonetic, isNotEmpty, reason: '${it.id} 缺狗语拟声');
        expect(it.meaning, isNotEmpty, reason: '${it.id} 缺 meaning');
        expect(it.purpose.length, greaterThan(10),
            reason: '${it.id} 的用途说明太敷衍');
        expect(it.keywords, isNotEmpty, reason: '${it.id} 没有触发词');
      }
    });

    test('触发词跨意图无重叠（否则匹配会打架）', () {
      final seen = <String, String>{};
      for (final it in kIntents) {
        for (final kw in it.keywords) {
          if (seen.containsKey(kw)) {
            fail('触发词 "$kw" 同时属于 ${seen[kw]} 和 ${it.id}');
          }
          seen[kw] = it.id;
        }
      }
    });

    test('资产路径函数与文件名规则一致', () {
      expect(callAsset('cat', 'come', 0), 'assets/sounds/cat_00_come.wav');
      expect(callAsset('dog', 'talk', 9), 'assets/sounds/dog_09_talk.wav');
    });

    test('连播次数配置覆盖全部意图且取值合理', () {
      for (final it in kIntents) {
        final n = repeatCount(it.id);
        expect(n, inInclusiveRange(1, 3), reason: '${it.id} 连播次数异常：$n');
      }
      // 安抚/入睡类只播一次，呼叫/玩驾驶类连播 3 次
      expect(repeatCount('sleep'), 1);
      expect(repeatCount('comfort'), 1);
      expect(repeatCount('come'), 3);
      expect(repeatCount('play'), 3);
      expect(repeatCount('stop'), 3);
    });

    test('60 条叫声音频真实存在于 assets/sounds/', () {
      // 从 test/ 到项目根
      final root = Directory.current.path;
      final dir = Directory('$root/assets/sounds');
      expect(dir.existsSync(), isTrue,
          reason: 'assets/sounds/ 目录不存在，先跑 tools/synth_calls.py');
      for (var i = 0; i < kIntents.length; i++) {
        final it = kIntents[i];
        for (final sp in const ['cat', 'dog']) {
          final f = File('${dir.path}/${callAsset(sp, it.id, i).split('/').last}');
          expect(f.existsSync(), isTrue, reason: '缺少 ${f.path}');
          expect(f.lengthSync(), greaterThan(5000),
              reason: '${f.path} 小得可疑，可能是空文件');
        }
      }
    });
  });

  // ============================================================
  // 翻译引擎
  // ============================================================
  group('translator engine', () {
    test('叫它过来：', () {
      final r = IntentMatcher.translate('过来');
      expect(r.intent.id, 'come');
      expect(r.matchedWords, contains('过来'));
      expect(r.confidence, 'high');
    });

    test('吃饭了 → 开饭', () {
      expect(IntentMatcher.translate('吃饭了').intent.id, 'eat');
      expect(IntentMatcher.translate('宝贝开饭啦').intent.id, 'eat');
    });

    test('骂它：坏蛋/又搞破坏', () {
      expect(IntentMatcher.translate('你这个坏蛋').intent.id, 'scold');
      expect(IntentMatcher.translate('怎么又搞破坏').intent.id, 'scold');
    });

    test('制止：不行/放下', () {
      expect(IntentMatcher.translate('不行不行').intent.id, 'stop');
      expect(IntentMatcher.translate('快放下').intent.id, 'stop');
    });

    test('夸奖：真乖/好棒', () {
      expect(IntentMatcher.translate('真乖').intent.id, 'praise');
      expect(IntentMatcher.translate('你好棒啊').intent.id, 'praise');
    });

    test('出去玩 → walk', () {
      expect(IntentMatcher.translate('出去玩吧').intent.id, 'walk');
      expect(IntentMatcher.translate('遛弯去').intent.id, 'walk');
    });

    test('该睡了 → sleep', () {
      expect(IntentMatcher.translate('睡觉觉了').intent.id, 'sleep');
      expect(IntentMatcher.translate('晚安宝贝').intent.id, 'sleep');
    });

    test('安抚：别怕', () {
      expect(IntentMatcher.translate('别怕别怕').intent.id, 'comfort');
      expect(IntentMatcher.translate('不怕不怕啊').intent.id, 'comfort');
    });

    test('陪它聊天：喜欢你/你好', () {
      expect(IntentMatcher.translate('喜欢你').intent.id, 'talk');
      expect(IntentMatcher.translate('你好呀').intent.id, 'talk');
    });

    test('长句带语气词也能命中', () {
      expect(IntentMatcher.translate('宝宝过来这边一下').intent.id, 'come');
      expect(IntentMatcher.translate('给你加餐吃小鱼干好不好').intent.id, 'eat');
    });

    test('没听清/语气词 → 兜底聊天', () {
      final r1 = IntentMatcher.translate('');
      expect(r1.isFallback, isTrue);
      expect(r1.intent.id, 'talk');
      final r2 = IntentMatcher.translate('嗯');
      expect(r2.isFallback, isTrue);
      final r3 = IntentMatcher.translate('[unk] [unk]');
      expect(r3.isFallback, isTrue);
    });

    test('识别文本里的空格（Vosk 分词）不影响匹配', () {
      expect(IntentMatcher.translate('过 来').intent.id, 'come');
      expect(IntentMatcher.translate('吃 饭 了').intent.id, 'eat');
    });

    test('纯 [unk] 混合词：有实体词仍能命中', () {
      final r = IntentMatcher.translate('[unk] 过来 [unk]');
      expect(r.intent.id, 'come');
    });
  });

  // ============================================================
  // 音色匹配档位
  // ============================================================
  group('pet profile playback rate', () {
    PetProfile p(String species, double hz) =>
        PetProfile(species: species, pitchHz: hz);

    test('未录入时用物种默认档', () {
      expect(p('cat', 0).playbackRate, 1.15);
      expect(p('dog', 0).playbackRate, 0.95);
    });

    test('高音宠物（猫 ~600Hz）→ 放快', () {
      expect(p('cat', 600).playbackRate, greaterThan(1.15));
    });

    test('低音宠物（大狗 ~90Hz）→ 放慢', () {
      expect(p('dog', 90).playbackRate, lessThan(1.0));
    });

    test('档位永远在 0.75~1.30 之间（防失真）', () {
      for (final hz in [40.0, 90.0, 110.0, 300.0, 600.0, 1200.0, 4000.0]) {
        final r = p('cat', hz).playbackRate;
        expect(r, inInclusiveRange(0.75, 1.30), reason: 'hz=$hz → $r');
      }
    });
  });

  // ============================================================
  // Vosk JSON 提取
  // ============================================================
  group('vosk json', () {
    test('partial', () {
      expect(textFromVoskJson('{"partial": "过 来"}'), '过 来');
    });
    test('final text', () {
      expect(textFromVoskJson('{"text": "吃 饭"}'), '吃 饭');
    });
    test('空对象', () {
      expect(textFromVoskJson('{}'), '');
    });
    test('乱输入不抛异常', () {
      expect(textFromVoskJson('not json at all'), '');
    });
  });
}
