import Foundation

@main
struct WatchQueueReadLatencySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        precondition(pullClient.contains("private let queueReadSettleDelay: TimeInterval = 0.12"),
                     "Queue read should start within the 100-200ms feedback window after GATT readiness")
        precondition(pullClient.contains("after: queueReadSettleDelay,\n                          reason: dataNotifyReady ? \"notify-ready\" : (queueReadRetries == 0 ? \"queue-first-gatt-settle\" : \"queue-first-retry-settle\")"),
                     "Initial and retry queue reads should use the named settle policy")
        precondition(pullClient.contains("dataNotifyReady ? \"notify-ready\""),
                     "Notify-ready queue read should use the same fast settle policy")
        precondition(!pullClient.contains("after: queueReadRetries == 0 ? 0.45 : 0.15"),
                     "Pull client should not keep the old 450ms first queue-read delay")

        print("watch_queue_read_latency_smoke passed")
    }
}
