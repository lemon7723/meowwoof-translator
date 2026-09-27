/// 毛语通 · 预设叫声库
///
/// 10 个意图场景 × 猫/狗两套叫声。每个叫声都有明确的「用途说明」——
/// 它想对宠物表达什么、起什么作用。这也是产品诚实性的落点：
/// 我们不假装"听懂宠物的语言"，而是把主人的人话映射成一组
/// 结构化、可复现的叫声信号，配合训练让宠物建立条件反射。
library;

/// 每个意图对应的叫声资产（species 取 'cat' / 'dog'）
String callAsset(String species, String id, int index) =>
    'assets/sounds/${species}_${index.toString().padLeft(2, '0')}_$id.wav';

class IntentCall {
  final String id;

  /// 场景名（人话侧）
  final String name;

  /// 触发词：离线识别命中任意一个即倾向该意图
  final List<String> keywords;

  /// 对宠物表达的意思（翻译展示用）
  final String meaning;

  /// 猫语拟声
  final String catPhonetic;

  /// 狗语拟声
  final String dogPhonetic;

  /// 这个叫声的用途说明（用户要求逐一说明）
  final String purpose;

  /// 使用 / 训练小贴士
  final String tip;

  const IntentCall({
    required this.id,
    required this.name,
    required this.keywords,
    required this.meaning,
    required this.catPhonetic,
    required this.dogPhonetic,
    required this.purpose,
    required this.tip,
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
    catPhonetic: '咪呜—— 咪呜——',
    dogPhonetic: '汪！汪汪！',
    purpose: '唤回指令。把跑远或躲起来的它叫回你身边，'
        '是训练"随叫随到"的核心信号。叫它过来后给点奖励，效果会越来越稳。',
    tip: '每次它真过来了就摸一摸或给零食，叫声=好事发生，它会越来越积极。',
  ),
  IntentCall(
    id: 'praise',
    name: '夸奖它',
    keywords: ['乖', '真乖', '好孩子', '好棒', '真棒', '聪明', '好样的', '厉害'],
    meaning: '你做得太棒了！',
    catPhonetic: '咕噜咕噜～ 咪~',
    dogPhonetic: '汪呜～ 汪汪！',
    purpose: '正向反馈。它做对事、听话时使用，让它把刚才的行为和"被表扬"绑在一起。',
    tip: '夸奖要紧跟它做对的那件事，晚超过 3 秒它就对不上号了。',
  ),
  IntentCall(
    id: 'scold',
    name: '骂它（做错事）',
    keywords: ['坏', '坏蛋', '讨厌', '不乖', '欠揍', '欠打', '怎么能这样', '又搞破坏', '淘气'],
    meaning: '你这样做不对！我生气了。',
    catPhonetic: '哈——！ 嘶……',
    dogPhonetic: '呜—— 汪！汪汪汪！',
    purpose: '表达不满。抓到它正在搞破坏、上桌子、挠沙发时使用，'
        '低沉急促的叫声配生气的表情，它读得懂"主人生气了"。',
    tip: '只抓现行，事后翻旧账它完全对不上号；骂完别马上哄，不然它会当成游戏。',
  ),
  IntentCall(
    id: 'stop',
    name: '制止它',
    keywords: ['不行', '不可以', '停下', '不许', '放下', '别动', '不能', '吐出来'],
    meaning: '停下！不许这样做。',
    catPhonetic: '咔—— 嘶！',
    dogPhonetic: '汪汪！ 呜汪！',
    purpose: '打断指令。它正在做危险或禁止的事（咬电线、扑人、翻垃圾）时立刻喊停。',
    tip: '制止后马上给它一个可以做的事（玩具、零食垫），它才知道"那我该干嘛"。',
  ),
  IntentCall(
    id: 'eat',
    name: '开饭啦',
    keywords: ['吃饭', '开饭', '吃饭了', '饿不饿', '加餐', '吃饭饭', '吃小鱼干', '吃零食', '喂你'],
    meaning: '饭点到了，开饭！',
    catPhonetic: '咪啊～！ 咪咪咪～',
    dogPhonetic: '汪汪！ 汪呜呜～',
    purpose: '进食信号。饭前播放并配合放碗动作，几天后单放叫声它就会主动跑向饭碗。',
    tip: '固定饭点 + 固定叫声，条件反射建立得最快；别在非饭点乱放，会把它绕晕。',
  ),
  IntentCall(
    id: 'play',
    name: '一起玩',
    keywords: ['玩', '玩吧', '玩耍', '逗你玩', '玩球', '来玩', '陪你玩', '玩一会儿'],
    meaning: '来玩呀！开心一点！',
    catPhonetic: '咪呜呜～ 咪！咪！',
    dogPhonetic: '汪！汪汪汪！ 嗷呜～',
    purpose: '邀请玩耍。上扬轻快的叫声配玩具晃动，用来发起互动、消耗它多余的精力。',
    tip: '每天固定来两轮"叫声→玩耍"，它听到声音就会主动叼玩具来找你。',
  ),
  IntentCall(
    id: 'walk',
    name: '出去玩',
    keywords: ['出去', '出门', '遛弯', '散步', '走走', '出去玩', '遛一遛'],
    meaning: '带我们出去玩！',
    catPhonetic: '咪~ 咪啊——',
    dogPhonetic: '汪汪汪！ 嗷呜——！',
    purpose: '出门信号。狗听到会兴奋预备，猫多用于陪遛/出门就医前降低紧张。',
    tip: '先播放再拿牵引绳，几次之后它一听到就会自己蹲在门口等。',
  ),
  IntentCall(
    id: 'sleep',
    name: '该睡了',
    keywords: ['睡觉', '睡吧', '晚安', '睡觉觉', '休息', '回窝', '该睡了'],
    meaning: '晚安，好好睡觉～',
    catPhonetic: '咕噜……咕噜……',
    dogPhonetic: '呜…… 汪呜……',
    purpose: '安抚入睡。低柔缓慢的叫声帮它平静下来，配合关灯形成固定的就寝仪式。',
    tip: '声音要轻，节奏要慢；坚持一周，它听到就会自己回窝。',
  ),
  IntentCall(
    id: 'comfort',
    name: '安抚它',
    keywords: ['别怕', '不怕', '没事', '勇敢', '摸摸', '抱抱你', '不怕不怕', '没事的'],
    meaning: '别怕，有我在。',
    catPhonetic: '咕噜咕噜～ 咪……',
    dogPhonetic: '呜～ 汪呜……',
    purpose: '情绪安抚。打雷、搬家、洗澡、就医这些紧张时刻使用，'
        '稳定低频的叫声有类似"母亲唤崽"的镇静作用。',
    tip: '安抚时语调放低放慢，抱紧或轻抚，别在这个时候突然做大动作。',
  ),
  IntentCall(
    id: 'talk',
    name: '陪它聊天',
    keywords: ['嗨', '你好', '嘿', '在干嘛', '喜欢你', '爱你', '对不起', '抱歉', '聊聊天', '小可爱'],
    meaning: '你好呀，我喜欢你。',
    catPhonetic: '咪~ 咪呜~ 咕~',
    dogPhonetic: '汪~ 汪呜~',
    purpose: '社交问候。没具体指令、单纯想搭理它或它主动来找你时使用，'
        '也是"没听懂你在说什么"时的默认友好回应。',
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
