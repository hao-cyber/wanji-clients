import Foundation

@main
struct NoDualBLEAutoStartSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("private func startWatchRequesterIfNeededForBinding()"),
                     "Automatic app-open path should route sync requester startup through an explicit gate")
        precondition(content.contains("sync requester skipped on automatic path bound=true"),
                     "Bound app-open path should not start the sync-command requester")
        precondition(content.contains("if watchBindingConfirmed {\n            debugLog(\"sync requester skipped on automatic path bound=true\")\n            return\n        }\n        watchSyncRequester.start()"),
                     "The sync requester should only auto-start when binding is still needed")
        precondition(content.contains("watchPullClient.start()\n                scheduleAutomaticWatchPull(reason: \"appear\")"),
                     "The bound app-open path should keep the pull client as the primary automatic sync path")
        precondition(content.contains(#"watchPullClient.syncNow(reason: "manual_button")"#),
                     "Manual sync should share the same pull-first BLE path as automatic sync")

        print("no_dual_ble_auto_start_smoke passed")
    }
}
