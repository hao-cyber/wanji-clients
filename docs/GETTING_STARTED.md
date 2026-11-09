# 构建、配对与第一次录音

## 选择正确的手表客户端

- 手表能安装 Android APK：尝试 `app/android-watch`。工程最低 API 23，编译 SDK 36。
- 手表运行兼容的 HarmonyOS 且可安装 ArkTS wearable 应用：使用 `app/harmony-watch`。
- 品牌或系列名称不能替代系统/API 信息。轻量系统、受限型号不一定支持第三方录音应用。
- Apple Watch 目前没有对应客户端。

首版为源码交付。需要自己的开发工具、设备调试权限，以及 iPhone/HarmonyOS 的签名配置。
工程里的 Bundle ID 是源码默认值；自行分发时应改成自己控制的标识。

## iPhone

1. 在 Xcode 打开 `app/wanji-ios/Wanji.xcodeproj`。
2. 在 Signing & Capabilities 选择自己的 Team，必要时更换 Bundle Identifier。
3. 选择自己的 iPhone，构建并运行。模拟器可以检查界面，但不能证明手表 BLE 可用。
4. 允许蓝牙权限。首次不需要配置远程服务。

如使用 XcodeGen 修改工程，编辑 `app/wanji-ios/project.yml` 后执行：

```sh
cd app/wanji-ios
xcodegen generate
```

签名证书、描述文件和团队私有配置不要提交。

## Android 手表

JDK 17、Android SDK Platform 36、Build Tools 36.0.0；设置 `JAVA_HOME` 与 `ANDROID_HOME`。
在自己的手表上开启开发者调试，按系统流程允许电脑连接，然后：

```sh
cd app/android-watch
./gradlew test assembleDebug
./install_watch.sh <设备序列号或IP:端口>
```

此脚本安装调试包；没有参数时只显示用法并退出，不选择默认设备。
正式 release 包需要自行配置发布签名。若已有版本签名不同，先导出未同步录音，
不要为解决安装错误直接卸载。

## HarmonyOS 手表

DevEco Studio 打开 `app/harmony-watch`，同步 Hvigor/SDK 并使用自己的开发者签名。
工程声明最低 HarmonyOS 5 / API 12，目标 SDK 为 `6.1.1(24)`，
实际设备能力仍需验证。详见[客户端说明](../app/harmony-watch/README.md)。

## 配对和同步

1. 在手表和 iPhone 上都打开腕记；iPhone 保持解锁与前台。
2. 使用手表的绑定入口，并在手机点击“绑定手表”，按界面提示完成运行时绑定。
3. 先录一段无敏感内容的短音频并停止，确认进入手表待同步队列。
4. 手机保持前台，等待自动同步；必要时使用手动同步入口。
5. 在手机播放，确认声音和时长完整，再检查手表队列与同步提示。

蓝牙绑定保护的是腕记自己的同步链路，不替代系统或华为运动健康的配对。
Android 使用手机拉取，HarmonyOS 使用推送兼容路径；不要跨版本任意修改协议 UUID。
协议测试通过也不能保证特定设备、固件或后台状态下的链路稳定。

## 可选的转写和纪要

打开手机设置，填写自己有权使用的兼容服务地址与令牌。公网服务必须使用 HTTPS；
本机开发允许 localhost HTTP。客户端使用[音频 API](api-contract.md)，
不是直接填写任意模型供应商的聊天接口即可使用。

未配置后端时可以继续录音、传输与播放。不要在公开 Issue 中粘贴配置链接或令牌。

## 真实设备验收

建议先验证短录音，再验证长录音、多文件队列、断连后重试和取消处理。
每次记录具体型号、系统版本、客户端提交与结果。失败后先确认本地音频仍在；
不要用清空数据或卸载来掩盖队列问题。公开报告使用脱敏摘要，原始录音和设备日志留在本机。
