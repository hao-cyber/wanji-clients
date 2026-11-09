# 腕记 HarmonyOS 手表客户端

ArkTS 手表录音客户端：音频先写入本地队列，通过运行时绑定的 BLE 链路交给
iPhone 腕记。当前模块不请求互联网权限；转写和纪要由手机按用户操作发起。

## 构建

1. 用 DevEco Studio 打开本目录，安装可解析本项目 `modelVersion: 6.1.1` 的工具链。
2. 工程声明最低 HarmonyOS `5.0.0(12)`，目标 `6.1.1(24)`；安装对应 SDK。
3. 在 Project Structure → Signing Configs 配置自己的开发者签名与设备。
4. 使用 DevEco 构建/运行，或在 macOS 使用 `./hdc_wanji.sh build` 构建未签名 HAP。

CLI 默认使用 `/Applications/DevEco-Studio.app`，可以通过 `DEVECO_SDK_HOME`、
`JAVA_HOME`、`N`（Node 路径）、`H`（hvigorw.js 路径）、`HDC` 覆盖。
其他安装位置优先使用 DevEco 自带终端或直接从 IDE 构建。

未签名产物通常位于 `entry/build/default/outputs/default/entry-default-unsigned.hap`。
它不等于可安装的正式发行包。签名、设备兼容性与商店提交需要使用者自行完成。

不需要填写 `Secrets.ets`；模板仅保留为历史开发格式说明。不要将用户令牌编译进应用。

## 连接自己的手表

在手表中开启开发者模式/无线调试，保持亮屏并按设备提示授权，然后使用实际地址：

```sh
WATCH_ADDR='<手表显示的IP:端口>' ./hdc_wanji.sh connect
./hdc_wanji.sh targets
HAP='<自己的已签名HAP路径>' ./hdc_wanji.sh install <target>
./hdc_wanji.sh start <target>
```

脚本只在明确的在线设备上安装；多设备时须指定 target。不要通过卸载已有应用
来处理签名冲突，否则可能丢失尚未同步的音频。

## 同步与验证边界

在手表开启短时绑定窗口，再用 iPhone 的绑定入口完成运行时绑定。手机和手表应用
保持前台。录音先持久化，再尝试传输；失败保留队列，手机确认接收后才完成同步。
手机传输入口固定为 `ble://wanji`。自动同步未完成时，可在手表点击“传到手机”重试；
未找到手机时，打开 iPhone 腕记并保持前台。

这里使用 BLE 推送及手机触发同步路径，与 Android 手表的拉取实现不同。
应成对验证 iOS 兼容性、断连恢复、队列持久化和长录音。
物理按键、息屏录音、耗电和具体型号兼容性需要真机验证；不能只凭构建成功宣称支持。

界面中的原产品在线隐私说明地址只是静态文字，未用于音频上传。
自行分发时按[隐私说明](../../docs/PRIVACY.md)更新政策与主体，并验证目标设备布局。
本次源码版的实际验证见[STATUS.md](../../docs/STATUS.md)。
