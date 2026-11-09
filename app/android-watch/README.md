# 腕记 Android 手表客户端

录制 AAC/m4a 到手表本地队列，通过 BLE GATT 向 iPhone 腕记提供拉取服务。
运行时绑定、队列、分段传输与 ACK 必须和 iOS 客户端一起维护。

## 构建

需要 JDK 17、Android SDK Platform 36 和 Build Tools 36.0.0。
设置 `JAVA_HOME`、`ANDROID_HOME` 后，在本目录运行：

```sh
./gradlew test assembleDebug
./install_watch.sh <设备序列号或IP:端口>
```

APK：`app/build/outputs/apk/debug/app-debug.apk`。
安装脚本必须明确选择设备。release 构建没有内置发布签名，也不会读取其他客户端的凭据文件。
公开构建固定以 `ble://wanji` 为手机传输入口。

最低 Android API 23，target API 31，compile API 36。这些是工程配置，
不代表每个手表型号都经过验证。没有 Google Play / AppGallery 已上架承诺。

调试构建包含录音与诊断入口，适用于自己的开发设备。录音、诊断输出、设备标识和密钥
不应进入公开仓库。应用卸载可能丢失未同步录音，遇到签名冲突先备份。

配对与失败恢复见[上手说明](../../docs/GETTING_STARTED.md)，当前证据见[验证状态](../../docs/STATUS.md)。
