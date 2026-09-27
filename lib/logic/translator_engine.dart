/// 毛语通 · 翻译引擎（纯 Dart，完全离线）
///
/// 输入：Vosk 离线识别出的人话文本（简体中文、无标点）
/// 输出：意图匹配结果（命中哪个预设叫声、为什么命中、置信度）
///
/// 匹配策略（按优先级）：
/// 1. 精确包含：文本包含某触发词 → 该词权重计入
/// 2. 词长度加权：长词（"吃饭饭"）比短词（"饭"）更可信
/// 3. 语气词/副词兜底：全都没命中 → 归入「陪它聊天」
library;

import '../data/call_library.dart';

class TranslatorResult {
  final String inputText;

  /// 命中的意图，没听清/无命中时为 talk 的兜底场景也返回非 null
  final IntentCall intent;

  /// 命中的触发词（可能有多个）
  final List<String> matchedWords;

  /// 置信度：high / medium / fallback
  final String confidence;

  const TranslatorResult({
    required this.inputText,
    required this.intent,
    required this.matchedWords,
    required this.confidence,
  });

  bool get isFallback => confidence == 'fallback';
}

class IntentMatcher {
  /// 语气词：识别结果里只有这些 → 视为没说清楚
  static const _fillers = {'嗯', '啊', '哦', '呃', '喂', '嘿', '呀', '嘛', '的', '了'};

  static String normalize(String raw) {
    var t = raw.trim().toLowerCase();
    // Vosk 结果形如 {"text": "过来 一下"}；引擎只拿纯文本
    t = t.replaceAll(RegExp('[，。！？、,.!?:：;；"\']'), '');
    // 词表语法外的词会被识别成 [unk]，过滤掉
    t = t.replaceAll('[unk]', '').trim();
    // Vosk 中文输出是分词带空格的（"过 来"），去掉空格再做包含匹配
    t = t.replaceAll(' ', '');
    return t;
  }

  static bool isMeaningless(String text) {
    final t = text.replaceAll(' ', '');
    if (t.isEmpty) return true;
    if (_fillers.contains(t)) return true;
    if (t.length <= 1 && '的了吗呢吧哟咯喽'.contains(t)) return true;
    return false;
  }

  static TranslatorResult translate(String rawText) {
    final text = normalize(rawText);

    if (isMeaningless(text)) {
      return TranslatorResult(
        inputText: text,
        intent: kIntents.last,
        matchedWords: const [],
        confidence: 'fallback',
      );
    }

    String bestId = '';
    double bestScore = 0;
    final matched = <String>[];

    for (final intent in kIntents) {
      var score = 0.0;
      final hits = <String>[];
      for (final kw in intent.keywords) {
        if (text.contains(kw)) {
          // 词越长越可信：1 字词 1.0 分，2 字词 1.6 分，3+ 字词 2.4 分
          final w = kw.length == 1 ? 1.0 : (kw.length == 2 ? 1.6 : 2.4);
          score += w;
          hits.add(kw);
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestId = intent.id;
        matched
          ..clear()
          ..addAll(hits);
      }
    }

    // 没有任何触发词命中，或只有泛化短词 → 兜底聊天
    if (bestId.isEmpty || bestScore < 1.0) {
      return TranslatorResult(
        inputText: text,
        intent: kIntents.last,
        matchedWords: matched,
        confidence: 'fallback',
      );
    }

    final intent = kIntents.firstWhere((e) => e.id == bestId);
    return TranslatorResult(
      inputText: text,
      intent: intent,
      matchedWords: List.unmodifiable(matched),
      confidence: bestScore >= 2.0 ? 'high' : 'medium',
    );
  }
}
