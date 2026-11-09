# 腕记 · Wanji

**抬腕记录，把声音带回手机。**

腕记是本地优先的手表录音工具。手表先保存音频，iPhone 通过蓝牙接收，
在本地管理、播放和分享；需要转写或会议纪要时，再主动连接自己配置的兼容服务。

[English](README.en.md) · [构建与配对](docs/GETTING_STARTED.md) · [验证状态](docs/STATUS.md) · [MIT 许可](LICENSE)

```text
手表录音 → 手表本地队列 → 蓝牙 → iPhone 本地音频
                                      ↓ 用户主动发起
                               可选 HTTPS 转写 / 纪要服务
```

## 这个仓库包含什么

| 组件 | 目录 | 说明 |
| --- | --- | --- |
| iPhone 客户端 | `app/wanji-ios` | SwiftUI，本地队列、播放、蓝牙同步、可选转写与纪要 |
| Android 手表客户端 | `app/android-watch` | Java，录音、本地队列、BLE 拉取服务 |
| HarmonyOS 手表客户端 | `app/harmony-watch` | ArkTS，录音、本地队列、BLE 推送与运行时绑定 |

这是面向开发者的首个公开源码版本。Android 与 HarmonyOS 是两条不同的手表实现；
能否安装取决于具体设备的系统和第三方应用能力，不能把所有华为手表视为通用兼容设备。
**没有 Apple Watch / watchOS 客户端。** 当前验证范围和未验证项目见[验证状态](docs/STATUS.md)。

音频后端不在本仓库，公开客户端不预置服务地址、账号或模型密钥。
录音、传输、播放不依赖转写服务。需要连接兼容服务时，参照[客户端 API 契约](docs/api-contract.md)。

## 开始使用

需要一台可安装对应客户端的手表，以及 iOS 17 或更新版本的 iPhone。
先从源码构建并安装两端，再按[配对步骤](docs/GETTING_STARTED.md#配对和同步)连接。
首次版本不提供 App Store / AppGallery 已上架或全机型验证的承诺。

### iPhone

macOS、Xcode 和 iOS SDK。仓库已包含 Xcode 工程；模拟器构建不需要开发者签名：

```sh
git clone https://github.com/hao-cyber/wanji-clients.git
cd wanji-clients
xcodebuild -project app/wanji-ios/Wanji.xcodeproj -scheme Wanji \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/wanji-derived-data CODE_SIGNING_ALLOWED=NO build
```

安装到自己的 iPhone 时，在 Xcode 中选择自己的开发团队和唯一 Bundle ID。
`project.yml` 是工程配置源；改动后可在 `app/wanji-ios` 执行 `xcodegen generate`。

### Android 手表

安装 JDK 17、Android SDK Platform 36 和 Build Tools 36.0.0，设置 `JAVA_HOME` 与 `ANDROID_HOME`：

```sh
cd app/android-watch
./gradlew test assembleDebug
```

调试 APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。
安装脚本要求显式指定自己的设备：`./install_watch.sh <设备序列号或IP:端口>`。
不要卸载已有应用来解决签名冲突；卸载可能删除尚未同步的录音。

### HarmonyOS 手表

用 DevEco Studio 打开 `app/harmony-watch`，安装项目要求的 HarmonyOS SDK，
配置自己的签名后构建。详细前提见[HarmonyOS 说明](app/harmony-watch/README.md)。

## 开发与测试

```sh
uv sync --dev --locked
uv run pytest
./scripts/check_swift_contracts.sh
```

Swift 检查需要 macOS / Swift；它们覆盖队列、音频保留和两端协议约定，
不等价于真实手表与 iPhone 的无线链路验收。CI 另外构建 iOS 模拟器应用和 Android 调试包。
修改 BLE UUID、帧格式、绑定或 ACK 语义时，需要同时验证两端。

## 数据与隐私

音频首先写入本地队列。传输或远程处理失败时保留本地音频供重试。
远程处理由用户主动发起；服务地址和令牌由使用者配置，令牌保存到 iOS Keychain。
连接第三方服务前，请了解该服务如何保留和处理录音。
调试日志、录音、签名材料和私人验收数据不应提交到仓库。详见[隐私说明](docs/PRIVACY.md)。

## 贡献与许可

欢迎提交有复现步骤的 Issue 和 PR，见[贡献说明](CONTRIBUTING.md)。
腕记源码使用 [MIT License](LICENSE)；随仓库分发的第三方构建工具保留各自许可，
见[第三方说明](THIRD_PARTY_NOTICES.md)。此源码许可不包含私有后端的访问权限。
