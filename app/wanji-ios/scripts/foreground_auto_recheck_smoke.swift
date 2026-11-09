import Foundation

@main
struct ForegroundAutoRecheckSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains(#".onChange(of: watchPullClient.lastEvent.occurredAt)"#),
                     "ContentView should react to every terminal pull event, including repeated messages")
        precondition(content.contains("handleWatchPullEvent(watchPullClient.lastEvent.message)"),
                     "Recheck handler should inspect the latest event message after each event timestamp changes")
        precondition(!content.contains(#".onChange(of: watchPullClient.lastEvent.message)"#),
                     "Recheck should not rely on message changes because repeated empty-queue events need polling")
        precondition(content.contains("private func handleWatchPullEvent(_ message: String)"),
                     "Foreground pull recheck should live behind an explicit handler")
        precondition(content.contains("guard scenePhase == .active,\n              watchBindingConfirmed,\n              !watchPullClient.syncing else"),
                     "Recheck should only run in foreground, after binding, and outside active sync")
        precondition(content.contains(#"case let value where value.contains("未发现") && value.contains("录音服务"):"#) &&
                     content.contains(#"case "未发现腕记蓝牙服务":"#) &&
                     content.contains(#"scheduleAutomaticWatchPull(reason: "not_found_recheck")"#),
                     "Not-found terminal states should schedule a foreground recheck")
        precondition(content.contains(#"case "手表录音队列暂时不可用":"#) &&
                     content.contains(#"scheduleAutomaticWatchPull(reason: "queue_unavailable_recheck")"#),
                     "Temporary queue failure should schedule a foreground recheck")
        precondition(content.contains(#"case "手表没有待同步录音":"#) &&
                     content.contains(#"debugLog("auto pull idle recheck skipped reason=empty_queue")"#),
                     "Empty queue should stop foreground polling instead of waking Bluetooth indefinitely")
        precondition(content.contains(#"case "not_found_recheck":"#) &&
                     content.contains("return 5.0"),
                     "Not-found recheck should be quick enough for a watch app opened shortly after the phone app")
        precondition(content.contains(#"case "bluetooth_unready_recheck":"#) &&
                     content.contains("return 5.0") &&
                     content.contains(#"case "手机蓝牙未就绪":"#) &&
                     content.contains(#"scheduleAutomaticWatchPull(reason: "bluetooth_unready_recheck")"#),
                     "Bluetooth readiness should be treated as a recoverable foreground recheck state")
        precondition(content.contains(#"case "queue_unavailable_recheck":"#) &&
                     content.contains("return 10.0"),
                     "Queue-unavailable recheck should retry without requiring user action")
        precondition(content.contains(#"if automaticRecheckPending { return "正在查找" }"#) &&
                     content.contains(#"if watchStatusWarning { return "查找手表" }"#),
                     "Pending foreground rechecks should feel active, not like the system has stopped")
        precondition(content.contains(#"return "靠近后自动同步。""#),
                     "Recoverable not-found copy should describe automatic foreground recheck without sounding technical")
        precondition(content.contains("private var autoRecoverableWatchError: Bool"),
                     "Recoverable queue failures should be classified separately from hard errors")
        precondition(content.contains(#"return "系统会自动重试。""#),
                     "Recoverable queue failure copy should avoid pushing the user toward re-binding")
        precondition(content.contains(#"if automaticRecheckPending { return .accentBlue }"#),
                     "Pending foreground rechecks should use an active status color")
        precondition(content.contains(#"if watchStatusWarning { return .accentBlue }"#),
                     "Recoverable foreground watch warnings should read as active automatic retry")
        precondition(!content.contains(#"return "稍后再查""#),
                     "Home status should not describe queued automatic work as a passive delay")
        precondition(!content.contains(#"return "打开手表端腕记后重试。""#),
                     "Home copy should not imply manual retry is required for foreground auto-recheck states")
        precondition(content.contains("@State private var automaticPullReason: String?"),
                     "UI should track whether an automatic foreground recheck is already queued")
        precondition(content.contains("private var automaticRecheckPending: Bool"),
                     "Home should expose a lightweight pending-recheck state")
        precondition(content.contains(#"case "bluetooth_unready_recheck", "not_found_recheck", "queue_unavailable_recheck"#),
                     "Pending recheck affordance should include recoverable Bluetooth failures")
        precondition(content.contains(#"Text(watchPullClient.syncing ? "同步中" : "查找中")"#) &&
                     content.contains(#"Label("重试", systemImage: "arrow.clockwise")"#) &&
                     content.contains(#".accessibilityLabel("重新查找手表录音")"#),
                     "Pending rechecks should show progress and failures should offer a semantic retry")
        precondition(content.contains("automaticPullReason = nil") &&
                     content.contains("automaticPullReason = reason"),
                     "Pending-recheck state should be cleared and set with the automatic pull work item")
        precondition(content.contains("private func cancelAutomaticWatchPull(reason: String)") &&
                     content.contains(#"cancelAutomaticWatchPull(reason: "manual_button")"#),
                     "Manual foreground search should cancel the queued automatic recheck")

        print("foreground_auto_recheck_smoke passed")
    }
}
