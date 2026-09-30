# 宠了么 v1.6.0 构建 + 雷电模拟器安装 执行手册

> 目标：出 **两个独立 APK** —— 一个给**真机**测试，一个给**雷电模拟器**测试；
> 然后把模拟器包安装进电脑上的雷电模拟器并运行。

---

## 0. 重要前提（本机情况说明）

当前这个 **WorkBuddy 沙箱环境里没有** Flutter / Android SDK / gradle / adb / 雷电控制台，
而且本机 `C:\Program Files\ldplayer9box` 只是模拟器**引擎**文件（VirtualBox 那套），
**没有** `LDPlayer.exe` / `dnplayer.exe` / `ldconsole.exe` / `adb.exe` 前端可执行文件。

所以**打包和安装都必须在你自己的开发电脑上执行**，下面给的是可直接照抄的命令。
（你电脑上已装好 Flutter 和雷电模拟器。）

---

## 1. 环境自检（开发电脑上）

```bat
flutter --version          && REM 需要 Flutter 3.x（建议 ≥ 3.24）
flutter doctor             && REM 确认 Android toolchain 全绿
adb version                && REM 雷电自带 adb，或 Android SDK 的 adb
```

若 `flutter doctor` 提示 Android license 未接受：
```bat
flutter doctor --android-licenses
```

---

## 2. 拉代码 + 取依赖

```bat
cd <你的项目根>\meowwoof_translator
flutter pub get
```

---

## 3. 出两个包（关键命令）

`android/app/build.gradle` 已经把 `abiFilters` 设为 **仅** `arm64-v8a` + `x86_64`，
配合 `--split-per-abi` 会**正好产出两个 APK**：

```bat
flutter build apk --release --split-per-abi
```

产物在：

```
build\app\outputs\flutter-apk\
    app-arm64-v8a-release.apk     ← 真机测试包（arm64 手机/平板）
    app-x86_64-release.apk        ← 雷电/安卓模拟器测试包（x86_64）
```

> 注意：**不要**用 `flutter build apk --release`（不分 ABI 的“通用包”在雷电上同样可能
> `INSTALL_FAILED_NO_MATCHING_ABIS`）。一定带 `--split-per-abi`。

---

## 4. 安装到雷电模拟器并运行

### 方式 A：命令行（推荐，最稳）

1. 先启动雷电模拟器（打开雷电多开器 / 雷电模拟器主程序），确保有一台实例在运行。
2. 找到雷电自带的 `adb`。通常在：
   ```
   C:\LDPlayer\LDPlayer9\adb.exe
   ```
   或你安装目录里的 `adb.exe`。把它加到 PATH，或下面直接用完整路径。
3. 连上模拟器（默认端口 5555，多开实例 5555/5557/5559…）：
   ```bat
   adb connect 127.0.0.1:5555
   adb devices                 && REM 确认 emulator-5554 / 127.0.0.1:5555 在线
   ```
4. 安装模拟器包：
   ```bat
   adb install -r build\app\outputs\flutter-apk\app-x86_64-release.apk
   ```
   `-r` = 覆盖安装（已装过旧版时用）。
5. 启动 App：
   ```bat
   adb shell monkey -p com.meowwoof.translator -c android.intent.category.LAUNCHER 1
   ```
   或在雷电里直接点图标启动。

### 方式 B：图形拖拽（最简单）

把 `app-x86_64-release.apk` 直接**拖进**雷电模拟器窗口，
雷电会自动 install 并提示“安装完成”，点图标即可运行。

---

## 5. 真机测试包怎么用

把 `app-arm64-v8a-release.apk` 拷到手机（微信/数据线/网盘都行），
手机上允许“未知来源”安装 → 装好 → 打开。

> 真机必须 **arm64-v8a**（现在主流安卓机都是）。别拿 x86_64 包装真机，
> 也别拿 arm64 包装雷电（会 NO_MATCHING_ABIS）。

---

## 6. 首跑必看：模型是远程下载的（不是打包进 APK）

v1.6.0 把 RTMPose 换成 **SuperAnimal HRNet-w32 INT8（24 关键点）**，模型**不在 APK 里**，
首次进入体态功能会让 App **联网下载**模型到本地（约几十 MB）。

- 真机/模拟器都要能联网（或你提前把模型放到 `ModelDownloadManager` 指定的缓存路径）。
- 下载完成前，体态识别会处于“降级”状态（相机/录像/音频照常可用，只是不出情绪）。
- 详见 `docs/CHANGELOG_v1.6.0.md` 的“需求 2 模型远程下载”。

---

## 7. 常见报错速查

| 现象 | 原因 | 解决 |
|---|---|---|
| `INSTALL_FAILED_NO_MATCHING_ABIS` | 拿错 ABI 的包 | 模拟器用 `app-x86_64-release.apk`，真机用 `app-arm64-v8a-release.apk` |
| `adb: device not found` | 雷电没启动 / 没 connect | 先开雷电，再 `adb connect 127.0.0.1:5555` |
| 相机打不开（模拟器） | 雷电默认没摄像头 | 雷电设置 → 手机 → 摄像头 选“开启”或用虚拟摄像头；代码已把摄像头 `required=false`，无摄像头也能装能跑（只是预览黑屏） |
| 体态一直“无宠物/降级” | 模型没下下来 | 检查网络 / 模型下载路径日志（`CameraRec` 标签） |
| `adb install` 卡住 | 之前实例占用 | 加 `-r` 覆盖，或 `adb uninstall com.meowwoof.translator` 后重装 |

---

## 8. 构建产物清单（交付）

| 文件 | 用途 |
|---|---|
| `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` | 真机测试 |
| `build/app/outputs/flutter-apk/app-x86_64-release.apk` | 雷电/模拟器测试 |
| `docs/CHANGELOG_v1.6.0.md` | 改动清单 + dart analyze 说明 |
| `docs/TEST_CHECKLIST_v1.6.0.md` | 真机测试清单 + 测试报告模板 |

---

## 9. iOS 说明（本版不做，仅留模板备忘）

本仓库**没有 `ios/` 目录**，本次只做 APK。后续做 IPA 时，分享功能需在
`ios/Runner/Info.plist` 加（模板，待建 iOS 工程时填）：

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>tiktok</string>
  <string>instagram</string>
  <string>twitter</string>
  <string>fb</string>
  <string>youtube</string>
</array>
```

（抖音/TikTok、IG、X、FB、YouTube 的 URL Scheme，用于“已安装才显示分享按钮”。）
