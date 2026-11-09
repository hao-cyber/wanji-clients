import Foundation

@main
struct WatchNotifyUnavailableReadFallbackSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)

        precondition(ios.contains("private func continueWithReadMode(_ peripheral: CBPeripheral, reason: String)") &&
                     ios.contains("readOnlyTransfer = true") &&
                     ios.contains("pull notify unavailable reason="),
                     "iPhone should have a named read-mode fallback when notify cannot be used")
        precondition(ios.contains("continueWithReadMode(peripheral, reason: \"notify-property-missing\")") &&
                     ios.contains("continueWithReadMode(peripheral, reason: \"notify-state-failed\")"),
                     "Missing notify capability and failed CCCD enable should both continue with read mode")
        precondition(!ios.contains(#"fail("手表录音流不可用")"#) &&
                     !ios.contains(#"fail("手表端需要更新后再同步")"#),
                     "Notify setup failure should not abort syncing when the read characteristic is available")
        precondition(ios.contains("scheduleQueueRead(from: peripheral, after: 0, reason: reason)") &&
                     ios.contains(#"data.append(notify ? UInt8(ascii: "n") : UInt8(ascii: "r"))"#),
                     "Fallback should read the queue and encode chunks in explicit binary read mode")

        print("watch_notify_unavailable_read_fallback_smoke passed")
    }
}
