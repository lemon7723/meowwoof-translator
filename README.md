# 毛语通 MeowWoof · v1.0.0

**离线猫狗翻译 App**：你说人话 → 手机离线识别 → 翻译成猫/狗叫声播放。
没有网络权限、没有任何联网 SDK、不依赖 Google 服务，华为手机可正常安装使用。

## 功能

| 功能 | 实现方式 |
|---|---|
| 听懂人话 | Vosk 离线中文识别（小模型 42MB，打进 APK），自由听写 + 关键词意图匹配 |
| 翻译成叫声 | 10 个意图（过来/夸奖/骂它/制止/开饭/玩耍/出门/睡觉/安抚/聊天）× 猫狗两套叫声 |
| 10 个预设叫声 | 每个都写明用途与训练小贴士（见 App 内"叫声库"页），猫狗可切换 |
| 录宠物声音 | 16kHz 录音 + 自相关音高分析（F0），得到它的基频 |
| 音色匹配 | 用它的基频给所有叫声变速变调（0.75x~1.30x），更像"它的声音" |
| 拍照/相册 | 设置宠物头像（系统相机/相册选择器，无需存储权限） |

## 目录

```
仓库根/
├── pubspec.yaml                                   # 版本 1.0.0+1
├── README.md
├── .github/workflows/build-apk.yml                # 云端打包（自动下载 Vosk 模型）
├── assets/sounds/*.wav                            # 20 条合成叫声（已提交，无需 CI 下载）
├── lib/
│   ├── main.dart                                  # 三页 UI（翻译/叫声库/我的毛孩）
│   ├── data/call_library.dart                     # 10 意图定义（触发词/拟声/用途说明）
│   ├── logic/translator_engine.dart               # 人话→意图匹配引擎
│   └── services/
│       ├── voice_bridge.dart                      # MethodChannel 封装
│       └── profile_store.dart                     # 宠物资料持久化
├── test/smoke_test.dart                           # 单元测试（引擎/叫声库/资产对账）
├── tools/
│   ├── synth_calls.py                             # 叫声合成脚本（numpy，可复现）
│   └── check_sounds.py                            # 音频质量校验脚本
└── android/
    ├── build.gradle / settings.gradle / gradle.properties
    └── app/
        ├── build.gradle                           # Vosk 0.3.47 + JNA（Maven Central）
        └── src/main/
            ├── AndroidManifest.xml                # 仅 RECORD_AUDIO 权限，纯离线
            └── kotlin/com/meowwoof/translator/MainActivity.kt   # BUILD_TAG = v1.0.0
```

## ⚠️ Vosk 中文模型（42MB）不进仓库

GitHub 网页单文件上传上限 25MB。本工程沿用"云端自动补齐"方案：

- CI 打包第一步会**自动下载** `vosk-model-small-cn-0.22.zip`（Apache 2.0）解包进 assets
- 所以仓库里只有代码，模型不用传
- 构建日志能看到「下载 vosk-model-small-cn-0.22...」+ 模型目录列表确认

## 云端打包（不需要本地环境）

1. GitHub 新建**空仓库**（不要勾选 README 初始化）
2. 把本目录全部文件网页上传（`.github` 是隐藏文件夹，确认传上；`assets/sounds/` 里 20 条 wav 也要传）
3. 仓库核对三条：根目录直接是 `pubspec.yaml`；`lib/main.dart` 存在；`MainActivity.kt` 含 `v1.0.0`
4. Actions → Build Android APK → Run workflow → 5-10 分钟 → Artifacts 下载 `meowwoof-apk`
5. 构建日志确认：模型下载步骤输出大小 ≥30MB；「无 Dart error 级问题」

## 手机安装

1. APK 传到手机（微信/QQ/数据线均可）
2. 设置 → 安全 → 安装外部来源应用 → 给传文件的 App 开允许
3. 被纯净模式拦截（华为）：设置 → 系统和更新 → 纯净模式 → 关闭后重装
4. 首次打开允许麦克风权限（识别和录音都需要）

## 验证新包生效

「我的毛孩」页底部版本行显示 `原生端 v1.0.1`（v1.0.0 有一个资源路径 bug：
原生层读 Flutter 资源时缺少 flutter_assets 前缀，导致全部叫声播放失败）。
任何语音模块报错都会带具体原因（权限/模型缺失/识别失败）。

## 使用建议（训练效果最大化）

- **一致性**：同一句话永远触发同一个叫声，这是条件反射成立的根本
- **即时奖励**：叫它过来→它真过来→立刻给零食，3 秒内
- **抓现行**：骂它/制止只在家被抓到正在做坏事时用，事后翻旧账无效
- **固定仪式**：开饭前、出门前、睡前各用固定叫声，一周左右见效

## 诚实边界

猫狗没有人类式语言，目前没有任何技术能"真翻译"人话成宠物语义。
本 App 的原理是**一致的声学信号 + 条件反射训练**：固定叫声 + 固定奖励，
让宠物把声音当指令记住。App 内也如实向用户展示了这一点。

## 技术边界与已知限制

- Vosk 中文小模型对**口音/方言/儿童**识别率会下降；识别结果只取关键词，容错尚可
- 叫声为**合成音**（谐波+噪声建模），清晰但音色偏"电子"；音色匹配只能整体变速变调，
  不能克隆真实宠物音色（那需要录音训练神经网络，超出本版本范围）
- iOS 未包含（需另配 Vosk iOS 模型与 Swift 桥接）；首次打开模型解包约 1~3 秒
