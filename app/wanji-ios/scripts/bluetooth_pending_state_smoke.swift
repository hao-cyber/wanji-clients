import Foundation

@main
struct BluetoothPendingStateSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        guard let delegateStart = pullClient.range(of: "func centralManagerDidUpdateState"),
              let discoverStart = pullClient.range(of: "func centralManager(_ central: CBCentralManager,\n                        didDiscover peripheral", range: delegateStart.upperBound..<pullClient.endIndex) else {
            preconditionFailure("Could not isolate centralManagerDidUpdateState")
        }
        let delegate = String(pullClient[delegateStart.lowerBound..<discoverStart.lowerBound])

        precondition(delegate.contains("central.state == .poweredOn, pendingSync"),
                     "Powered-on Bluetooth should immediately resume a pending pull scan")
        precondition(delegate.contains("central.state == .unknown || central.state == .resetting"),
                     "Transient Bluetooth startup states should be handled separately")
        precondition(delegate.contains("if pendingSync {\n                syncing = true\n                setStatus(\"手机蓝牙准备中\", severity: .processing)\n            }"),
                     "Unknown/resetting Bluetooth should preserve pending sync and visible feedback")
        precondition(delegate.contains("pendingSync = false") &&
                     delegate.contains("setStatus(\"手机蓝牙未就绪\", severity: .warning)"),
                     "Hard Bluetooth unavailable states should still clear pending sync")

        print("bluetooth_pending_state_smoke passed")
    }
}
