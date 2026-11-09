import Foundation

@main
struct WatchSyncVisibleProgressSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("return watchPullClient.lastEvent.message"),
                     "Watch panel subtitle should surface the active BLE sync stage")
        precondition(content.contains("watchBindPreparing\n            || watchPullClient.syncing"),
                     "Watch console should stay visible during connection, queue reads, and transfers")
        precondition(content.contains("private var shouldExpandWatchPanel: Bool") &&
                     content.contains("!watchBindingConfirmed\n            || shouldShowWatchConsole") &&
                     !content.contains("|| (watchBindingConfirmed && watchStatusWarning)"),
                     "Retryable warnings should remain compact while first connection and actionable progress expand")
        precondition(content.contains("if event.message.contains(\"查找\") { return \"正在查找\" }") &&
                     content.contains("if event.message.contains(\"连接\") { return \"正在连接\" }") &&
                     content.contains("if event.message.contains(\"读取\") { return \"正在读取\" }"),
                     "Watch console title should map BLE stages to readable progress labels")
        precondition(content.contains("if syncing {\n            return event.message\n        }"),
                     "Watch console message should show the current BLE stage instead of a generic saving message")

        let pull = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                              encoding: .utf8)
        precondition(pull.contains("scanAttemptSuffix") &&
                     pull.contains("未发现腕记蓝牙服务"),
                     "Pull client should expose scan retries and distinguish missing WristNote BLE service")
        precondition(pull.contains("watchNameFallback") &&
                     pull.contains("normalizedName.contains(\"huawei watch\")") &&
                     pull.contains("fallback_service_missing"),
                     "Pull client should try a bound Huawei Watch broad-scan fallback and recover if its GATT service is missing")

        print("watch_sync_visible_progress_smoke passed")
    }
}
