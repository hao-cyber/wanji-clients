import Foundation

@main
struct BluetoothPrimaryUISmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent("Wanji/AppSettings.swift"),
                                  encoding: .utf8)
        let info = try String(contentsOf: root.appendingPathComponent("Info.plist"),
                              encoding: .utf8)

        precondition(content.contains(#".navigationTitle("腕记")"#) &&
                     content.contains("private var watchSummaryRow: some View"),
                     "The compact home should keep watch sync visible without a promotional hero")
        precondition(content.contains("private var watchPrimaryAction: some View"),
                     "The watch card should expose one primary action")
        precondition(content.contains(#"Text(watchPullClient.syncing ? "同步中" : "查找中")"#) &&
                     content.contains(#"Label("重试", systemImage: "arrow.clockwise")"#) &&
                     content.contains(#".frame(minWidth: 72, minHeight: 44)"#),
                     "Exceptional watch states should expose clear progress or a semantic retry action")
        precondition(content.contains(#"Text("允许同步")"#) &&
                     content.contains("不会改变华为运动健康的配对"),
                     "App-level authorization should not be confused with system watch pairing")
        precondition(content.contains("BluetoothWatchPullClient"),
                     "iPhone should keep the pull-first Bluetooth sync path")
        precondition(content.contains(#"watchPullClient.syncNow(reason: "manual_button")"#),
                     "Manual sync should use the pull client directly")
        precondition(content.contains(".refreshable {") &&
                     content.contains("requestWatchSyncNow()"),
                     "Manual watch sync should use pull-to-refresh on the recording list")
        precondition(content.contains(#"Label("导入音频", systemImage: "square.and.arrow.down")"#),
                     "Manual import should remain available in data management")
        precondition(!content.contains("复制 WiFi 配置"),
                     "WiFi copy action should not be visible")
        precondition(!content.contains("上传地址"),
                     "HTTP upload endpoint should not be visible")
        precondition(!content.contains("watchSyncRequester.requestSync(force: true)"),
                     "The UI should not keep the old phone command service sync path")
        precondition(!settings.contains("watchConfigSnippet"),
                     "HTTP watch config helper should be removed")
        precondition(!settings.contains("receiverPort"),
                     "HTTP receiver port should be removed from app settings")
        precondition(!info.contains("NSLocalNetworkUsageDescription"),
                     "Bluetooth-only app should not request local network permission")

        print("bluetooth_primary_ui_smoke passed")
    }
}
