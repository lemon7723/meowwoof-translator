# 宠了么 (MeowWoof) v1.6.0 改动清单

版本号：`pubspec.yaml` → `version: 1.6.0+15`
升级路径：v1.5.6 → v1.6.0
策略：**APK 优先**（iOS 仅留模板备忘，不做本版）；不连 git / 不推送（待你给凭证）。

---

## 一、11 项需求 → 落地文件对照

| # | 需求 | 落地文件 / 改动 |
|---|---|---|
| 1 | 模型升级 HRNet-w32 INT8 24 关键点，替换 RTMPose | `PoseEstimator.kt`（HRNet heatmap argmax + 1/4 像素细化）；删除 `models/rtm_animal_fp16.tflite`、`models/yolov8n-pose_fp32.tflite` |
| 2 | 模型远程下载（不打包进 APK） | `ModelDownloadManager.kt`（下载到 cache，校验最小字节）；首次进入体态时按需下载 |
| 3 | SSD 4MB 前置检测常开 | **新增** `pose/SsdDetector.kt`（`pet_ssd_mobilenet_int8.tflite`，COCO cat=16/dog=17，CONF≥0.5；缺模型/失败则降级“始终有宠物”，不阻塞体态） |
| 4 | 实时**视频**推理（非单张照片），A13 强制每 3 帧 | **新增** `pose/CameraRecorder.kt`（Camera2 + ImageReader YUV_420_888 → 每帧推理；`NORMAL_FRAME_SKIP=2`，`A13_FRAME_SKIP=3`，`SSD_FRAME_SKIP=4`） |
| 5 | 24 关键点索引表 + 重写 姿态→情绪 规则 | `PoseRules.kt`（24 点索引 + 规则）、`EmotionFusion.kt`（多帧融合） |
| 6 | 设备能力 3 档弹窗 | `device_capability.dart` + `pose/DeviceCapability.kt`（`meowwoof/device` 通道） |
| 7 | 关于页 设备指南 + Apache-2.0 合规 | `About` 页（设备指南）；`NOTICE.md` / `README.md`（Apache-2.0 文本保留） |
| 8 | 音画同步录像 + 边录边叫 | `pose/CameraRecorder.kt`（MediaCodec H264/AAC → MediaMuxer MP4，情绪文字烧录 + 麦克风分流 + 叫声混入）；`video_record_service.dart`（`meowwoof/capture` 通道） |
| 9 | 社交分享（TikTok/IG/X/FB/YouTube + 系统） | `share_service.dart` + `pose/ShareManager.kt`（`meowwoof/share` 通道；FileProvider 跨应用分享 MP4） |
| 10 | 保留原模块 + 修 `${f.poseEmotion}` 渲染、去内置 TTS、免责声明图标按钮、代码注释 | `lib/pages/pose_page.dart` 等（修插值 bug、移除 TTS 依赖、免责按钮）；全程补注释 |
| 11 | `dart analyze` 干净 + 改动清单 + 真机测试清单 + 测试报告 | 本文件 + `TEST_CHECKLIST_v1.6.0.md`；`dart analyze` 见下节 |

---

## 二、本次（v1.6.0）实际改动文件清单

### 新增
- `android/app/src/main/kotlin/com/meowwoof/translator/pose/SsdDetector.kt`
- `android/app/src/main/kotlin/com/meowwoof/translator/pose/CameraRecorder.kt`
- `android/app/src/main/res/xml/file_paths.xml`（FileProvider 路径）
- `docs/CHANGELOG_v1.6.0.md`、`docs/TEST_CHECKLIST_v1.6.0.md`、`docs/BUILD_INSTALL_RUNBOOK.md`

### 修改
- `android/app/build.gradle` → `abiFilters` 改为仅 `arm64-v8a` + `x86_64`（配合 `--split-per-abi` 正好两个包）
- `android/app/src/main/kotlin/com/meowwoof/translator/MainActivity.kt`
  → `configureFlutterEngine` 注册 `meowwoof/device` / `meowwoof/share` / `meowwoof/capture` 三通道 + `CameraPreviewFactory`（viewType `meowwoof/camera_preview`）；保留原 voice/pose 通道
- `android/app/src/main/AndroidManifest.xml`
  → 新增 `${applicationId}.fileprovider` FileProvider；`uses-feature` camera/autofocus/microphone `required=false`（无摄像头的雷电也能装）
- `lib/pages/pose_page.dart` → 补 `import 'dart:async'`（用 `Timer` 必加，否则 `dart analyze` 报错）

### 删除
- `models/rtm_animal_fp16.tflite`（27.5MB，旧 RTMPose）
- `models/yolov8n-pose_fp32.tflite`（13.3MB，旧 YOLO 姿态）

> `models/` 目录保留但为空（HRNet 走远程下载，不进 APK，也不在 pubspec assets 里）。

---

## 三、`dart analyze` 说明

本沙箱无 Flutter，无法实跑 `dart analyze`。已静态排查并修掉会导致 **报错**（非仅警告）的点：

1. `pose_page.dart` 使用 `Timer` 但缺 `dart:async` 导入 → 已补 `import 'dart:async';`（这是确定会红的硬错）。
2. Dart ↔ 原生通道方法名 / 参数键 已逐条对齐：
   - `open` ← `{postureEnabled, isA13}`
   - `startPosture` / `stopPosture`
   - `startRecord` → `bool`；`stopRecord` → `{path}`
   - `playCall` ← `{asset, rate}`；`stopCall`
   - 事件 `onCapture` → `{emotion, detail, lowLight, hasPet}`；`onRecordState` → `bool`
   - `device`：`detect`；`share`：`checkInstalled` ← `{packages}` / `shareTo` ← `{package, path}`
3. Kotlin 侧同步修掉的编译隐患（否则 gradle 红）：
   - `CameraRecorder.playCall()` 原在主线程跑 `AudioTrack.write` 死循环 → **ANR**，已移到 `callExecutor` 后台线程；
   - `CameraRecorder.stopRecord()` 原在主线程 `Thread.sleep(200)` + 释放编码器 → **卡 UI**，已挪到 `recordHandler`；
   - `CameraPreviewView` 仍在 `implements SurfaceViewLike`，而该接口已被删 → **未解析引用**，已移除接口与冗余 `getSurface()`。

**建议在你开发电脑上跑一遍确认：**
```bat
flutter pub get
dart analyze
```
期望：无 error（允许个别 info/style 级提示，已在 `analysis_options.yaml` 收敛）。

---

## 四、需要真机/模拟器实测微调的项（代码已注释标出）

`CameraRecorder.kt` 顶部文档块与各常量已注明，下列项**别在没实测前改死**：

- 录制分辨率 / 码率 / 帧率：`captureW/H`、`VIDEO_BITRATE=2_000_000`、`REC_FPS=30`
- 暗光阈值：`LOW_LIGHT_LUMA = 28f`（低于即禁用体态，UI 提示）
- 竖屏旋转角：`frameRotation`（前后摄/厂商不同，模拟器通用近似 90°）
- 情绪文字在视频里的位置/字号：`drawEmotionOverlay`（当前右下角，`textSize = 宽*0.06`）
- SSD 检测节流：`SSD_FRAME_SKIP = 4`（检测到宠物才跑 HRNet）

---

## 五、降级与异常兜底

- 模型缺失 / 下载失败 / 推理异常：全部 try-catch 降级，**不影响相机、音频、叫声库、分享**等其它模块（需求 6/10）。
- SSD 模型缺失：默认“画面有宠物”，继续跑 HRNet（不卡流程）。
- 无摄像头设备（如未开摄像头的雷电）：`uses-feature required=false`，能装能跑，仅预览黑屏。

---

## 六、本轮（Step1 全量读码 + 核查）发现与处理

**已修正的硬问题（不修则 gradle / 运行必炸）：**
1. `CameraRecorder.playCall()` 原在主线程跑 `AudioTrack.write` 死循环 → **ANR**，已移到 `callExecutor` 后台线程。
2. `CameraRecorder.stopRecord()` 原在主线程 `Thread.sleep(200)` + 释放编码器 → **卡 UI**，已挪到 `recordHandler`。
3. `CameraRecorder.CameraPreviewView` 仍 `implements SurfaceViewLike`（接口已被删）→ 未解析引用编译错误，已移除接口与冗余 `getSurface()`。
4. `android/app/build.gradle` 的 `abiFilters` 原含 3 个 ABI（会出 3 个包），已收紧为 `arm64-v8a + x86_64`，配合 `--split-per-abi` 正好出你要的**两个包**。

**本轮小修（spec 合规 / 一致性）：**
5. `MainActivity.kt` 的 `BUILD_TAG` 由 `v1.5.9` 修正为 `v1.6.0`（版本字符串一致）。
6. `pose_page.dart` 分享按钮：未安装对应 App 时，按钮置灰 + 文案/tooltip 显示 `App not installed`（需求 9.1 字面要求）。
7. `pose_page.dart` 补 `import 'dart:async'`（用 `Timer` 必加，否则 `dart analyze` 红）。
8. `lib` 全量 grep 确认已无 `tts / flutter_tts / SpeechSynthesis` 残留 → 内置 TTS 自动朗读已彻底移除（需求 10）。

**静态核查确认与 spec 一致的点：**
- 设备三档弹窗英文文案、`不再提示` 勾选、`Use Audio Only` / `Force Enable Posture Detection (Not Recommended)` / `Continue` / `Turn off posture detection` —— 与需求 6 逐字一致。
- 模型下载：主地址 + FALLBACK_URLS、3 次重试 @2s、百分比进度、SHA-256 校验、cache 复用、断点续传（`ModelDownloadManager.kt`）—— 与需求 2 一致。
- About 页 Device Guide 文案（含 3 项 Important Notes）与需求 7 逐字一致；模型来源 + Apache-2.0 声明在「开源致谢 / 模型来源」卡（需求 11）。
- 体态规则六类（耳后压/蜷缩/夹尾/压低趴卧/舒展/炸毛）+ 24 点索引表 + 音频×体态融合表（含冲突/单源兜底）—— 与需求 5 一致；2 张校准参考图仅开发内部，不打包（代码注释声明，需求 5）。
- 音画同步录像 + 边录边叫（选叫声→播放并混入录像音轨，可切换）+ 麦克风分流 + 情绪文字烧录 —— 与需求 8 / 8.1 一致。
- 分享：先检测安装、未装置灰、TikTok/IG/X/FB 走 `ACTION_SEND` 草稿、YouTube 打开 App 并提示手传、`System Share` 走 `share_plus` —— 与需求 9 一致。

---

## 七、仍需你提供的模型资产（无法由代码生成，属“交付前置条件”）

- **HRNet-w32 INT8 模型文件**（`superanimal_hrnet_w32_int8.tflite`，≈54.6MB）：
  - 当前 `ModelDownloadManager.MODEL_URL` 是占位 `https://github.com/your-org/...`，需换成你托管的可直链；并把真实 `SHA-256` 填入 `EXPECTED_SHA256`（留空仅做大小 + 试加载校验）。
  - 模型导出须与 `PoseEstimator.kt` 约定对齐：输入 `[1,3,H,W]`（H/W 从模型读）、输出热力图 `[1,24,oH,oW]`（可选 offset `[1,48,...]`）、24 点顺序见 `PoseEstimator.KPT_NAMES`、置信阈值 0.3。
- **SSD 前置检测模型**（`pet_ssd_mobilenet_int8.tflite`，≈4MB）：
  - 当前 `assets/` 内**没有该文件** → `SsdDetector` 会降级为“始终有宠物”，需求 3 暂不真正生效。
  - 需把模型放入 `assets/pet_ssd_mobilenet_int8.tflite`，并在 `pubspec.yaml` 的 `assets:` 增加 `- assets/pet_ssd_mobilenet_int8.tflite`；COCO 类别确认 cat=16 / dog=17（不符则改 `SsdDetector.CAT_ID/DOG_ID`）。
  - 不强制打包也可走“运行时下载”，但当前实现是从 `assets` 拷 cache，二选一即可，记得同步改 `SsdDetector.loadFromAssets` 或下载逻辑。

---

## 八、dart analyze / 真机·模拟器测试 执行说明（本沙箱无法跑，列命令给你）

本工作环境**无 Flutter / Android SDK / adb**，故 ① 静态检查与 ③ 真机·雷电测试只能在你的开发电脑执行：

```bat
flutter pub get
dart analyze                 # 期望：无 error
flutter build apk --release --split-per-abi   # → app-arm64-v8a-release.apk + app-x86_64-release.apk
```
- 雷电装模拟器包：`adb connect 127.0.0.1:5555 && adb install -r build\app\outputs\flutter-apk\app-x86_64-release.apk`
- 真机装 `app-arm64-v8a-release.apk`。
- 测试清单与报告模板见 `docs/TEST_CHECKLIST_v1.6.0.md`，逐项验证后填表输出。

**静态层已确认无报错风险点**（已修）：`SurfaceViewLike` 未解析引用、主线程 ANR、主线程 sleep、缺失 `dart:async` 导入。其余 Dart/Kotlin 以你电脑 `dart analyze` + 真机跑测为准。

---

## 九、UI 变更核查记录（2026-10-01）

- **基准**：用户上传的「旧版UI参考截图」（`微信图片_20260930002053_172_2.jpg`）。
- **结论：基准无效，测试按规则 5 立即暂停，未进入 TEST_CHECKLIST 全套功能测试。**

### 9.1 差异报告（阻断项）

1. **基准截图不包含宠了么任何页面**：上传图片为 iPhone 桌面（iOS 主屏：日历/天气小组件、照片/相机/时钟/备忘录/设置等图标、Dock 栏），无 Pet Mood Capture 页、录音页、导出成功页、About 页、免责声明入口中的任何一个 → 五项逐页比对全部无法执行。
2. **步骤 1（编译 x86_64 包 + 安装雷电）本工作环境无法执行**：无 Flutter / Android SDK / adb / LDPlayer 控制台，需在开发 PC 上按 `BUILD_INSTALL_RUNBOOK.md` 完成后再比对。

### 9.2 静态代码审计（代码层证据，非视觉比对结论）

| 页面 | 本次新增控件（代码确认） | 原有元素是否变动（静态判断） |
|---|---|---|
| ① Pet Mood Capture | 设备三档弹窗（可"不再提示"）、体态识别开关、模型下载进度页、暗光 HUD、REC 计时 | ⚠️ 文件头注释自述「v1.6.0 重写」；原有「拍照识别 / 从相册选」两键现仅出现在**相机不可用的降级分支**，若旧版常驻主界面 → 属「原有按钮可见性变更」候选异常 |
| ② 录音页（record_page.dart） | **无**（该页未新增任何控件） | ❌ 与核查标准不符：**【边录边叫】按钮不在录音页**，实际在 Pet Mood Capture 页录制中显示（`pose_page._pickAndPlayCall`）。需确认归属页 |
| ③ 录像导出成功 | 一行社交分享按钮组：TikTok / Instagram / X / Facebook / YouTube / System Share（未装置灰 + `App not installed`） | 无独立"导出成功页"：分享行追加在捕获页控制区（`_shareRow`），原预览/导出控件未动 |
| ④ About | 追加「Pet Mood Capture - Device Guide」卡片（位于功能说明与隐私说明之间） | 原卡片顺序与内容未动；仅版本号文字 v1.5.x → v1.6.0（版本号随版本更新，例外项） |
| ⑤ 免责声明入口 | — | 右上角 ⓘ 独立小图标，点击才弹窗，进页不自动弹 ✅（代码层符合） |

### 9.3 异常判定与回滚触发条件

- 因基准无效，「是否改动原有页面 UI」**暂无法判定**，不输出通过结论。
- 静态层发现的候选异常（待正确截图确认后定性）：
  1. 「拍照识别 / 从相册选」按钮可见性变化（① 页）→ **已于 9.5 修复：两键下移到 `_controls` 常驻展示，恢复原有可见性**；
  2. 【边录边叫】按钮位置与核查标准不一致（② vs ① 页归属待确认）。
- 回滚原则不变：任何原有按钮移位、颜色改动、布局变动 → 回滚对应 UI 代码。

### 9.4 恢复测试所需补件（用户）

1. 重新上传**正确的旧版 UI 截图**，至少 5 张：① Pet Mood Capture 页 ② 录音页 ③ 录像导出成功页 ④ About 页 ⑤ 免责声明弹窗。
2. 明确【边录边叫】按钮的归属页（录音页 or Pet Mood Capture 录像控制区）。
3. 在开发 PC 执行：`flutter build apk --release --split-per-abi` → `adb connect 127.0.0.1:5555` → 装 `app-x86_64-release.apk` 至雷电。

---

## 十、UI 修复与方案调整（2026-10-01，用户确认）

### 10.1 方案调整
- **取消旧版截图比对**：用户决定暂不上传旧版 UI 截图，改为**本地 PC 雷电模拟器实测验证**；云端不再执行截图比对任务。
- **需求变更确认**：【边录边叫】按钮确认置于 **Pet Mood Capture 页录制控制区**（录制中显示），**不放入录音页**。代码现状已符合（`record_page.dart` 无任何边录边叫控件），无需改动。
- **其余 UI 约束不变**：本次迭代仅新增控件/弹窗；原有页面布局、配色、其他按钮位置禁止改动；About、免责声明逻辑保持现有代码不变。

### 10.2 高优先级 UI 修复（已落地 `lib/pages/pose_page.dart`）

- **问题**：原「拍照识别 / 从相册选」两键仅出现在 `_previewArea` 的 `!_cameraReady` 相机降级分支，正常相机预览态不显示 → 改动原有控件可见性，违反 UI 约束（需求 10 要求保留原有单张识别入口且位置不变）。
- **修复动作**：
  1. 从 `_previewArea` 降级分支移除这两键；
  2. 下移到 `_controls` 控制列，**常驻展示**（位于「开始/停止录像」按钮行下方），正常预览态、相机降级态、`done` 态始终可见；
  3. 降级分支仅保留提示文案「相机实时预览需要 Android 设备（仍可使用下方「拍照识别 / 从相册选」）」，避免重复按钮。
- **功能影响**：两键逻辑由 `_pickPhoto(ImageSource.camera/gallery)` 驱动，与相机预览无关，常驻后拍照/相册单张识别功能不受任何影响。

### 10.3 后续执行（用户本地 PC）
- 打包、`adb` 安装至雷电、UI 肉眼对比、TEST_CHECKLIST_v1.6.0.md 全功能测试，全部在用户本地开发电脑执行；云端停止相关比对任务。

---

## 十一、打包校验记录（2026-10-01 01:12 GMT+8）

### 11.1 工具链探测结果（已实测）
在 WorkBuddy 沙箱执行 `command -v flutter/dart/java/gradle/adb`，结果全部为 **NO**（沙箱无 Flutter / Dart / Java / Gradle / adb 任何一项）。
**结论：下列步骤无法在沙箱执行，需在你本地开发 PC 完成。**

| 步骤 | 命令 | 沙箱状态 | 本地 PC |
|---|---|---|---|
| 静态校验 | `flutter pub get && dart analyze` | ❌ 无法执行 | ✅ 必跑，确认无 error |
| Release 打包 | `flutter build apk --release --split-per-abi` | ❌ 无法执行 | ✅ 产出两个 APK |

### 11.2 `dart analyze` 结果（沙箱替代静态预检）
- 沙箱内无法运行 `dart analyze`，故对 `lib/**/*.dart` + `android/**/*.kt` 共 **31 个文件** 做了**括号配平静态检查**（忽略字符串/注释的 advisory 级检查）。
- **结果：OK — 未检测到明显括号/大括号/方括号配平破损**，即本次 v1.6.0 全部改动（含第十节拍照/相册常驻修复）未引入结构性语法破损。
- **权威结论以你本地 PC 的 `dart analyze` 为准**（期望：无 error；Warning 级可记录不阻断）。

### 11.3 控件位置静态确认（拍照/相册常驻修复后）
- `lib/pages/pose_page.dart` 关键行号：
  - 边录边叫按钮 → 录制控制区 `line 578 / 595`（`_recording` 时显示，符合需求 8.1 与第十节确认）✅
  - 拍照识别 / 从相册选 → 已下移 `_controls` 常驻 `line 600–616`（正常预览态始终可见）✅
  - 相机降级分支 `line 459 / 471` → 仅保留提示文案，无重复按钮 ✅

### 11.4 打包产物（状态：未生成，待本地 PC）
- 期望产物（本地执行后生成）：
  - `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` —— **真机**
  - `build/app/outputs/flutter-apk/app-x86_64-release.apk` —— **雷电模拟器**
- 沙箱**未生成任何 APK**；APK 需在你本机 Flutter 环境获取，WorkBuddy 沙箱无法直接产出可下载安装包。

### 11.5 本地 PC 执行命令（打包 + 装雷电）
```bat
flutter pub get
dart analyze                                   # ① 确认无 error
flutter build apk --release --split-per-abi    # ② 产出两个 APK
:: 雷电装模拟器包（x86_64）
adb connect 127.0.0.1:5555
adb install -r build\app\outputs\flutter-apk\app-x86_64-release.apk
:: 真机装 arm64 包
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

### 11.6 校验通过判定（本地 PC 跑完才算）
- `dart analyze` 无 error；
- 两个 APK 成功产出且体积正常（arm64 约含 HRNet 远程占位、x86_64 同理）；
- `adb install` 到雷电成功 → 即可开始人工测试（按 TEST_CHECKLIST_v1.6.0.md 逐项）。

> 说明：本章仅记录打包**校验动作与状态**。沙箱因无工具链，实际编译与 APK 产出必须由你本地 PC 完成；云端已做尽力的静态预检（括号配平 + 控件位置确认）。
