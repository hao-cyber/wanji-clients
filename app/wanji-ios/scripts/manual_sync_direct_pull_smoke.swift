import Foundation

@main
struct ManualSyncDirectPullSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)
        guard let functionStart = content.range(of: "private func requestWatchSyncNow()"),
              let nextFunction = content.range(of: "private func bindWatchNow()", range: functionStart.upperBound..<content.endIndex) else {
            preconditionFailure("Could not isolate requestWatchSyncNow")
        }
        let function = String(content[functionStart.lowerBound..<nextFunction.lowerBound])

        precondition(function.contains(#"watchPullClient.syncNow(reason: "manual_button")"#),
                     "Manual sync button should use the same direct pull path as automatic app-open sync")
        precondition(function.contains(#"cancelAutomaticWatchPull(reason: "manual_button")"#),
                     "Manual sync should cancel any queued foreground recheck before starting direct pull")
        precondition(function.contains("watchPullClient.start()"),
                     "Manual sync should ensure the pull client is ready before requesting sync")
        precondition(!function.contains("watchSyncRequester.requestSync"),
                     "Manual sync should not scan the separate sync-command service before pulling recordings")
        precondition(!function.contains("manualWatchSyncRequested = true"),
                     "Manual sync should rely on pull-client syncing state instead of a separate fake preparing state")
        precondition(content.contains("private func cancelAutomaticWatchPull(reason: String)") &&
                     content.contains("automaticPullWorkItem?.cancel()") &&
                     content.contains("automaticPullReason = nil"),
                     "Manual sync cancellation helper should clear pending automatic pull state")

        print("manual_sync_direct_pull_smoke passed")
    }
}
