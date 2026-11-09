# 腕记 iPhone 客户端

SwiftUI / iOS 17+。通过蓝牙接收手表录音，先存入本地队列，再提供播放、分享和
用户主动发起的可选转写/纪要功能。

```sh
xcodebuild -project Wanji.xcodeproj -scheme Wanji \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/wanji-derived-data CODE_SIGNING_ALLOWED=NO build
```

真机安装时选择自己的开发团队与 Bundle ID。修改 `project.yml` 后可用
`xcodegen generate` 重新生成工程。签名材料不在仓库中。

公开构建不预置后端地址。蓝牙同步和本地播放不需要后端账号。
需要转写/纪要时，在设置中配置有权访问的兼容服务；服务令牌写入 Keychain。
手机应保持前台、解锁并允许蓝牙权限，模拟器不用于证明 BLE 真机可用。

Android 手表走 BLE 拉取服务，HarmonyOS 手表走推送兼容路径。
Android 路径由 iPhone 主动拉取，成功落盘后才发送 ACK：

```text
打开腕记 -> 自动查找已绑定手表 -> 读取手表录音队列 -> 拉取录音 -> 本机保存 -> ACK -> 继续下一条
```

完整步骤见[上手说明](../../docs/GETTING_STARTED.md)，
接口见[API 契约](../../docs/api-contract.md)，
数据处理见[隐私说明](../../docs/PRIVACY.md)。
