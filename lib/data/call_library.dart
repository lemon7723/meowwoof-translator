/// 宠了么 · 预设叫声库（v1.1 行为学修订版）
///
/// 10 个意图场景 × 猫/狗两套叫声。文案依据动物行为学研究修订：
///
/// 猫科依据：Schötz "MEOWSIC" 项目猫声分类（基于 Moelk 1944 与声学分析）：
/// - 咕噜（purr）：闭口音，"我不构成威胁"的信号，也在饥饿索求/紧张时出现
/// - 颤音（trill/chirrup）：软卷舌短音，友好接近与问候，母猫唤崽的"过来"信号
/// - 喵（meow）：成年猫主要对人类使用，索求注意/食物/开门，音色因情境而变
/// - 哈气（hiss/spit）：受惊后的非自主防御警告，张口露齿
/// - 低吼（growl）：低频脉冲调制长音，警告/驱赶
/// 犬科依据：Yin & McCowan 2004（Animal Behaviour）+ Faragó et al. 2017：
/// - 低频粗糙不圆滑吠 = 警戒/干扰情境；高频圆滑有调制吠 = 玩耍/孤立求助
/// - 玩耍低吼比威胁低吼音高更高、更短促；人可听辨护食吼/对陌生吼/玩耍吼
/// - 呜咽（whine）：高音有调制，挫折/期待/分离信号
/// - 通用规律（Morton 1977）：低频=敌意，高频圆滑=友善接近
library;

/// 每个意图对应的叫声资产（species 取 'cat' / 'dog'）
/// v1.2.1：每个意图固定播放主文件（不再随机轮换变体）。
String callAsset(String species, String id, int index, {int variant = 0}) {
  final i = index.toString().padLeft(2, '0');
  if (variant <= 0) return 'assets/sounds/${species}_${i}_$id.wav';
  return 'assets/sounds/${species}_${i}_${id}_v$variant.wav';
}

/// 每意图变体数（资产仍保留 v1.2 的 3 变体以备用，播放端固定用主文件）
const Map<String, int> kCatVariants = {
  'come': 3, 'praise': 3, 'scold': 3, 'stop': 3, 'eat': 3,
  'play': 3, 'walk': 3, 'sleep': 3, 'comfort': 3, 'talk': 3,
};
const Map<String, int> kDogVariants = {
  'come': 3, 'praise': 3, 'scold': 3, 'stop': 3, 'eat': 3,
  'play': 3, 'walk': 3, 'sleep': 3, 'comfort': 3, 'talk': 3,
};

int variantCount(String species, String id) =>
    (species == 'cat' ? kCatVariants[id] : kDogVariants[id]) ?? 1;

/// 每意图连播次数（叫声太短时重复 2-3 次）
const Map<String, int> kRepeatCounts = {
  'come': 3, 'praise': 2, 'scold': 2, 'stop': 3, 'eat': 2,
  'play': 3, 'walk': 2, 'sleep': 1, 'comfort': 1, 'talk': 2,
};

int repeatCount(String id) => kRepeatCounts[id] ?? 2;

class IntentCall {
  final String id;

  /// 场景名（人话侧）
  final String name;

  /// 触发词：识别命中任意一个即倾向该意图
  final List<String> keywords;

  /// 对宠物表达的意思（翻译展示用）
  final String meaning;

  /// 猫语拟声
  final String catPhonetic;

  /// 狗语拟声
  final String dogPhonetic;

  /// 这个叫声的用途说明（含科学依据）
  final String purpose;

  /// 使用 / 训练小贴士
  final String tip;

  /// 每次触发连播次数（叫声太短时重复 2-3 次更接近真实呼唤）
  final int repeats;

  const IntentCall({
    required this.id,
    required this.name,
    required this.keywords,
    required this.meaning,
    required this.catPhonetic,
    required this.dogPhonetic,
    required this.purpose,
    required this.tip,
    this.repeats = 2,
  });

  String phonetic(String species) =>
      species == 'cat' ? catPhonetic : dogPhonetic;
}

/// 10 个预设叫声，顺序即列表展示顺序
const List<IntentCall> kIntents = [
  IntentCall(
    id: 'come',
    name: '叫它过来',
    keywords: ['过来', '来', '到我这边', '回来', '到这儿来', '过来这边', '回来吧'],
    meaning: '到我这边来！',
    catPhonetic: '咪噜噜～ 咪噜噜～（颤音）',
    dogPhonetic: '汪！汪！（短促高音）',
    purpose: '唤回指令。猫侧用的是"颤音（trill）"——母猫唤崽回身边的本能信号，'
        '行为学上它天然就是"过来"的意思（Schötz MEOWSIC 分类）；'
        '狗侧用高频短促吠——Yin & McCowan（2004）发现高频圆滑的吠出现在'
        '友善接近与召唤情境，低频粗糙吠则用于警戒，所以唤回绝不用低吼式吠。',
    tip: '叫声一响它就回头/走近，立刻给零食或抚摸——3 秒内。'
        '反复配对，"这声音=好事"的联结会越来越牢。',
  ),
  IntentCall(
    id: 'praise',
    name: '夸奖它',
    keywords: ['乖', '真乖', '好孩子', '好棒', '真棒', '聪明', '好样的', '厉害'],
    meaning: '你做得太棒了！',
    catPhonetic: '咕噜咕噜～ 咪~',
    dogPhonetic: '汪汪！汪呜～（高音轻快）',
    purpose: '正向反馈。猫侧用咕噜（purr）——"我不构成威胁、我很舒服"的信号，'
        '配合抚摸时猫也常以咕噜回应，是最自然的"满意"表达；'
        '狗侧用高音调、有节制的轻快吠——玩耍情境吠的高频特征'
        '（Yin & McCowan 2004）让它一听就放松。',
    tip: '夸奖要紧跟它做对的那件事，晚超过 3 秒它就对不上号了。',
  ),
  IntentCall(
    id: 'scold',
    name: '骂它（做错事）',
    keywords: ['坏', '坏蛋', '讨厌', '不乖', '欠揍', '欠打', '怎么能这样', '又搞破坏', '淘气'],
    meaning: '你这样做不对！我生气了。',
    catPhonetic: '哈——！嘶！（防御警告）',
    dogPhonetic: '呜噜—— 汪汪！（低吼转吠）',
    purpose: '表达不满。猫侧用哈气（hiss）——猫受惊/表达"退后"的本能防御音，'
        '对猫来说是意义最明确的拒绝信号；狗侧用低吼（growl）开头转吠——'
        '低频信号传递敌意（Morton 1977），是犬类"停止"的本能语言。'
        '注意：只是表达"我不喜欢这个行为"，不是吓唬它。',
    tip: '只抓现行，事后翻旧账它完全对不上号；骂完别马上哄，不然它会当成游戏。',
  ),
  IntentCall(
    id: 'stop',
    name: '制止它',
    keywords: ['不行', '不可以', '停下', '不许', '放下', '别动', '不能', '吐出来'],
    meaning: '停下！不许这样做。',
    catPhonetic: '嘶——！（短促哈气）',
    dogPhonetic: '汪汪！汪！（两声果断吠）',
    purpose: '打断指令。与"骂它"的区别：制止是短促的一声警告，'
        '目标是让它此刻停下而不是害怕你。猫用一声哈气，狗用两声果断的中频吠——'
        '既保持权威感又不至于让小体型犬受惊。',
    tip: '制止后马上给它一个可以做的事（玩具、零食垫），它才知道"那我该干嘛"。',
  ),
  IntentCall(
    id: 'eat',
    name: '开饭啦',
    keywords: ['吃饭', '开饭', '吃饭了', '饿不饿', '加餐', '吃饭饭', '吃小鱼干', '吃零食', '喂你'],
    meaning: '饭点到了，开饭！',
    catPhonetic: '咪啊～！咪啊～！（索求喵）',
    dogPhonetic: '汪！汪汪！（兴奋期待吠）',
    purpose: '进食信号。成年猫的喵主要对人类使用，'
        '其中"索求型喵"（solicitation meow）正是要饭/要开门的专用音'
        '（MEOWSIC：meow 常用于向人索求食物）；'
        '狗侧用期待性吠叫——食物期待情境的短促吠+呜咽混合（Yin 2002）。',
    tip: '固定饭点 + 固定叫声，几天后单放声音它就会跑向饭碗。'
        '别在非饭点乱放，会稀释信号。',
  ),
  IntentCall(
    id: 'play',
    name: '一起玩',
    keywords: ['玩', '玩吧', '玩耍', '逗你玩', '玩球', '来玩', '陪你玩', '玩一会儿'],
    meaning: '来玩呀！开心一点！',
    catPhonetic: '咪！咪！（短促游戏音）',
    dogPhonetic: '汪汪汪！嗷呜～（玩耍吠）',
    purpose: '邀请玩耍。狗侧用典型玩耍吠——高频、圆滑、连串有节奏'
        '（Yin & McCowan 2004 的 play situation 特征）；'
        '猫侧用短促游戏喵+追逐前的轻快音节——玩耍时的猫常发出'
        '短高频音节（trill-meow / chirp 家族，MEOWSIC）。',
    tip: '每天固定来两轮"叫声→玩耍"，它听到声音就会主动叼玩具来找你。',
  ),
  IntentCall(
    id: 'walk',
    name: '出去玩',
    keywords: ['出去', '出门', '遛弯', '散步', '走走', '出去玩', '遛一遛'],
    meaning: '带我们出去玩！',
    catPhonetic: '咪啊—— 咪～（期待喵）',
    dogPhonetic: '汪汪！汪汪汪！（出门兴奋吠）',
    purpose: '出门信号。狗听到会兴奋预备（出门前吠是典型兴奋吠），'
        '猫多用于陪遛/就医出门前建立"这个声音=要出门"的可预期信号，'
        '可预期性本身就能降低猫的出门紧张。',
    tip: '先播放再拿牵引绳，几次之后它一听到就会自己蹲在门口等。',
  ),
  IntentCall(
    id: 'sleep',
    name: '该睡了',
    keywords: ['睡觉', '睡吧', '晚安', '睡觉觉', '休息', '回窝', '该睡了'],
    meaning: '晚安，好好睡觉～',
    catPhonetic: '咕噜……咕噜……（纯咕噜）',
    dogPhonetic: '呜～……（轻呜咽渐弱）',
    purpose: '安抚入睡。猫侧用纯咕噜——低频规律振动有类似白噪音的镇静效果，'
        '也是猫感觉安全时的伴睡声；狗侧用极轻的呜咽渐弱收尾——'
        '模拟窝里同伴入睡前的低鸣，帮助它平静下来。',
    tip: '声音要轻，节奏要慢；坚持一周，它听到就会自己回窝。',
  ),
  IntentCall(
    id: 'comfort',
    name: '安抚它',
    keywords: ['别怕', '不怕', '没事', '勇敢', '摸摸', '抱抱你', '不怕不怕', '没事的'],
    meaning: '别怕，有我在。',
    catPhonetic: '咕噜咕噜～（稳定咕噜）',
    dogPhonetic: '呜～ 呜……（低柔呜咽）',
    purpose: '情绪安抚。咕噜的"我不构成威胁"信号在紧张时刻放给猫听，'
        '配合轻抚相当于用猫自己的语言说"安全"；'
        '狗侧用低柔呜咽——同为社交性寻求接触的音，'
        '表达陪伴而非指令（whine 的 affiliation 用法）。',
    tip: '安抚时语调放低放慢，抱紧或轻抚，别在这个时候突然做大动作。',
  ),
  IntentCall(
    id: 'talk',
    name: '陪它聊天',
    keywords: ['嗨', '你好', '嘿', '在干嘛', '喜欢你', '爱你', '对不起', '抱歉', '聊聊天', '小可爱'],
    meaning: '你好呀，我喜欢你。',
    catPhonetic: '咪噜～ 咪～（颤音+喵）',
    dogPhonetic: '汪～ 汪呜～（友好短吠）',
    purpose: '社交问候。猫侧用颤音+短喵——颤音正是猫之间的友好问候音，'
        '对人说"嗨"时猫也常用这一族；'
        '狗侧用轻快的单声短吠——问候情境的高频吠，'
        '是"没听懂你在说什么"时的默认友好回应。',
    tip: '日常多用，叫声=友好的陪伴，这是所有其他指令的感情基础。',
  ),
];

/// 意图 id → 在 kIntents 里的下标
int indexOfIntent(String id) =>
    kIntents.indexWhere((e) => e.id == id);

/// 汇总全部触发词（去重）。目前识别走自由听写 + 引擎匹配，
/// 此函数保留给未来可能的词表语法或搜索功能使用。
List<String> allKeywords() {
  final set = <String>{};
  for (final it in kIntents) {
    set.addAll(it.keywords);
  }
  return set.toList(growable: false);
}
