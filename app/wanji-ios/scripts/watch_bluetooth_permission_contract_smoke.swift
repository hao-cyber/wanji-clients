import Foundation

@main
struct WatchBluetoothPermissionContractSmoke {
    static func main() throws {
        let appRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()

        let module = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/module.json5"),
                                encoding: .utf8)
        precondition(module.contains(#""name": "ohos.permission.ACCESS_BLUETOOTH""#),
                     "Harmony watch app must declare Bluetooth access permission for BLE phone upload")
        precondition(module.contains(#""reason": "$string:bluetooth_reason""#),
                     "Bluetooth permission should have a user-visible reason")

        let strings = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/resources/base/element/string.json"),
                                 encoding: .utf8)
        precondition(strings.contains(#""name": "bluetooth_reason""#),
                     "Bluetooth permission reason string should exist")
        precondition(strings.contains("通过蓝牙把手表录音传到手机腕记"),
                     "Bluetooth permission reason should explain the phone relay use case")

        let index = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/ets/pages/Index.ets"),
                               encoding: .utf8)
        precondition(index.contains("const BLUETOOTH_PERMISSION: Permissions = 'ohos.permission.ACCESS_BLUETOOTH'"),
                     "Index page should use the declared Bluetooth permission")
        precondition(index.contains("return isValidPhoneToken(this.phoneToken)"),
                     "Bluetooth permission should only be requested after a valid runtime phone binding")
        precondition(!index.contains("Secrets.PHONE_TOKEN"),
                     "Harmony release must not compile a shared phone token into the app")
        precondition(index.contains("if (!await this.ensureBluetoothPermission())"),
                     "Upload should check Bluetooth permission before BLE transfer")
        precondition(index.contains("throw new Error('ERROR: 请允许蓝牙权限后重试')"),
                     "Denied Bluetooth permission should produce a retryable queue error")
        precondition(index.contains("this.statusNote = failed.lastError"),
                     "Error screen should show the retry guidance stored on the queue item")
        precondition(index.contains("Button('传到手机')"),
                     "Watch UI should expose a manual phone-transfer button when automatic BLE retry has queued audio")
        precondition(index.contains("Text('轻点传到手机')"),
                     "Queued watch recordings should explain the manual BLE retry affordance")
        precondition(index.contains("this.statusNote = '正在找手机腕记'"),
                     "Manual BLE retry should acknowledge the tap before scanning")

        let bluetoothUploader = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/ets/net/BluetoothUploader.ets"),
                                           encoding: .utf8)
        precondition(bluetoothUploader.contains("未找到手机腕记，请打开 iPhone 腕记并保持在前台"),
                     "BLE scan timeout should tell the user how to recover")
        precondition(bluetoothUploader.contains("蓝牙连接超时，请打开手机腕记后重试"),
                     "BLE connect timeout should be user-readable")

        let uploader = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/ets/net/Uploader.ets"),
                                  encoding: .utf8)
        precondition(uploader.contains("text: '已传到手机'"),
                     "BLE success should only claim transfer to the phone, not note generation")
        precondition(!uploader.contains("text: '已通过蓝牙传到手机，正在生成纪要'"),
                     "BLE success cannot know whether the phone backend is configured")

        let readme = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/README.md"),
                                encoding: .utf8)
        precondition(readme.contains("ble://wanji"),
                     "README should document the Bluetooth phone relay configuration")
        precondition(readme.contains("传到手机"),
                     "README should document the manual transfer fallback")

        print("watch_bluetooth_permission_contract_smoke passed")
    }
}
