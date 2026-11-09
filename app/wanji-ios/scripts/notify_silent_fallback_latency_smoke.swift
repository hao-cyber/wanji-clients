import Foundation

@main
struct NotifySilentFallbackLatencySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        precondition(pullClient.contains("private let notifyQuietTimeout: TimeInterval = 12.0"),
                     "Notify-mode silence after the first packet should allow transient Android/iOS notification stalls before recovery")
        precondition(pullClient.contains("private let notifyFirstChunkTimeout: TimeInterval = 25.0"),
                     "The first notify packet needs a longer cold-start timeout")
        precondition(pullClient.contains("private let readQuietTimeout: TimeInterval = 8.0"),
                     "Read fallback should keep the more conservative timeout")
        precondition(pullClient.contains("private let notificationEnableFallbackDelay: TimeInterval = 1.0") &&
                     pullClient.contains("deadline: .now() + notificationEnableFallbackDelay"),
                     "Missing notify-enable callbacks should fall back to read quickly instead of waiting several seconds")
        precondition(pullClient.contains("let timeout = shouldUseNotifyStream\n            ? (currentOffset == 0 ? notifyFirstChunkTimeout : notifyQuietTimeout)\n            : readQuietTimeout"),
                     "Chunk watchdog should allow a longer first notify packet timeout, then use the shorter timeout while notify streaming is active")
        precondition(!pullClient.contains("private let chunkQuietTimeout: TimeInterval = 8"),
                     "The old single 8s watchdog should stay removed")
        precondition(pullClient.contains("pull notify silent fallback to read offset=") &&
                     pullClient.contains("pull notify silent reconnect offset=") &&
                     pullClient.contains("self.resumeTransfer(after: 0.8, reason: \"notify_silent\")") &&
                     pullClient.contains("self.dataNotifyReady = false") &&
                     pullClient.contains("self.requestChunk()"),
                     "Notify silence after progress should reconnect/resume, while first-packet silence can still degrade to the read-based recovery path")

        print("notify_silent_fallback_latency_smoke passed")
    }
}
