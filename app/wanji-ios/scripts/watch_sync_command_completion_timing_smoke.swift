import Foundation

@main
struct WatchSyncCommandCompletionTimingSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let requester = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchSyncRequester.swift"),
                                   encoding: .utf8)

        precondition(requester.contains("private let disconnectCompletionFallbackDelay: TimeInterval = 0.6"),
                     "Sync command completion fallback should be fast enough to start pull sync promptly")
        precondition(requester.contains("waitingForDisconnect ? disconnectCompletionFallbackDelay : 0.2"),
                     "Disconnect fallback should use the named fast timing policy")
        precondition(!requester.contains("waitingForDisconnect ? 3.0 : 0.2"),
                     "Sync command completion should not keep the old three-second fallback")
        precondition(requester.contains(#"finishPendingSyncCommand(reason: "disconnect")"#),
                     "Real disconnect should still complete the sync command immediately when it arrives")

        print("watch_sync_command_completion_timing_smoke passed")
    }
}
