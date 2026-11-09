import Foundation

@main
struct PullOnlySyncUICleanupSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(!content.contains("manualWatchSyncRequested"),
                     "Pull-only sync UI should not keep the obsolete manual sync preparing flag")
        precondition(!content.contains("watchCommandPreparing"),
                     "Pull-only sync UI should not expose the old sync-command preparing state")
        precondition(!content.contains("正在唤起") && !content.contains("唤起中"),
                     "User-facing sync copy should no longer mention the old wake-command path")
        precondition(content.contains(#"watchPullClient.syncNow(reason: "manual_button")"#),
                     "Manual sync should still use the direct pull path")
        precondition(content.contains("preparing: watchBindPreparing"),
                     "The watch console should still show binding progress when binding is active")

        print("pull_only_sync_ui_cleanup_smoke passed")
    }
}
