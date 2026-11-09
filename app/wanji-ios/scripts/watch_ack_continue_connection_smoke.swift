import Foundation

@main
struct WatchAckContinueConnectionSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        precondition(pullClient.contains("pull ack continue on existing connection"),
                     "ACK continuation should reuse the existing GATT connection")
        precondition(pullClient.contains("private let ackContinueQueueReadDelay: TimeInterval = 0.06") &&
                     pullClient.contains(#"scheduleQueueRead(from: target, after: ackContinueQueueReadDelay, reason: "ack-continue")"#),
                     "ACK continuation should read the next queue item without a scan/reconnect delay")
        precondition(pullClient.contains("resetTransferStateForNextQueue()"),
                     "ACK continuation should clear per-item transfer state before reading the next queue item")
        precondition(pullClient.contains(#"syncNow(reason: "ack_reconnect_fallback")"#),
                     "If connection reuse is unavailable, the fallback path should be explicitly logged")
        precondition(pullClient.contains("DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)"),
                     "Reconnect fallback should not keep the old one-second inter-item delay")
        precondition(pullClient.contains("private let ackWriteTimeout: TimeInterval = 2.0") &&
                     pullClient.contains("private var ackWatchdogWorkItem: DispatchWorkItem?"),
                     "ACK writes should have a bounded watchdog instead of leaving sync stuck forever")
        precondition(pullClient.contains("scheduleAckWatchdog(id: id, continueSyncing: continueSyncing)") &&
                     pullClient.contains("pull ack write timeout id=") &&
                     pullClient.contains(#"reason: "ack_timeout""#) &&
                     pullClient.contains("retryPendingAckAfterReconnect(id: id,"),
                     "ACK watchdog should reconnect and retry the pending ACK instead of pretending the ACK succeeded")
        precondition(pullClient.contains("pull ack unavailable id="),
                     "Missing ACK characteristic should fall back to the continuation flow instead of silently hanging")
        precondition(pullClient.contains("pull ack write completion ignored no pending ack"),
                     "Late ACK callbacks after a watchdog should be ignored")

        print("watch_ack_continue_connection_smoke passed")
    }
}
