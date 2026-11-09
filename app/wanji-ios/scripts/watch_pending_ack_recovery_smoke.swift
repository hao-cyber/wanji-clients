import Foundation

@main
struct WatchPendingAckRecoverySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        precondition(pullClient.contains(#"private let pendingAckDefaultsKey = "wanji.watchPull.pendingAckID""#) &&
                     pullClient.contains("private var pendingAckID: String?") &&
                     pullClient.contains("private func rememberPendingAck(id: String)") &&
                     pullClient.contains("private func clearPendingAck(id: String?)"),
                     "Pull client should persist a pending watch ACK across reconnects/relaunches")
        precondition(pullClient.contains("self.rememberPendingAck(id: id)") &&
                     pullClient.range(of: "self.rememberPendingAck(id: id)")!.lowerBound <
                     pullClient.range(of: "self.ackItem(id: id, continueSyncing: true)")!.lowerBound,
                     "Saved watch audio should be marked pending-ACK before writing ACK to the watch")
        precondition(pullClient.contains("pull pending ack before queue id=") &&
                     pullClient.contains("ackItem(id: pendingAckID, continueSyncing: true)") &&
                     pullClient.range(of: "ackItem(id: pendingAckID, continueSyncing: true)")!.lowerBound <
                     pullClient.range(of: "scheduleQueueRead(from: peripheral,\n                          after: queueReadSettleDelay")!.lowerBound,
                     "After reconnect, the client should ACK the saved item before reading the next queue entry")
        precondition(pullClient.contains("pull ack write timeout id=") &&
                     pullClient.contains(#"reason: "ack_timeout""#) &&
                     !pullClient.contains("self.finishAckFlow(continueSyncing: continueSyncing)\n        }\n        ackWatchdogWorkItem = item"),
                     "ACK timeout should not be treated as successful ACK continuation")
        precondition(pullClient.contains(#"reason: "disconnect_before_ack""#) &&
                     pullClient.contains("pull pending ack reconnect id="),
                     "Disconnect after save but before ACK should reconnect to confirm the pending ACK")
        precondition(pullClient.contains("clearPendingAck(id: awaitingAckID)") &&
                     pullClient.range(of: "clearPendingAck(id: awaitingAckID)")!.lowerBound <
                     pullClient.range(of: "finishAckFlow(continueSyncing: continueAfterAck)")!.lowerBound,
                     "Pending ACK should be cleared only after a successful ACK write callback")

        print("watch_pending_ack_recovery_smoke passed")
    }
}
