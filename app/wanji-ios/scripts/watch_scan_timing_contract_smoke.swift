import Foundation

@main
struct WatchScanTimingContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)
        guard let scanStart = pullClient.range(of: "private func scan(preservingTransfer: Bool"),
              let retryStart = pullClient.range(of: "@discardableResult", range: scanStart.upperBound..<pullClient.endIndex) else {
            preconditionFailure("Could not isolate Bluetooth scan function")
        }
        let scanFunction = String(pullClient[scanStart.lowerBound..<retryStart.lowerBound])

        precondition(pullClient.contains("private let narrowScanFallbackDelay: TimeInterval = 0.35"),
                     "Narrow service scan should fall back quickly when advertisements omit service UUIDs")
        precondition(pullClient.contains("private let broadScanTimeout: TimeInterval = 4.5"),
                     "Broad filtered scan should not keep the old eight-second timeout")
        precondition(scanFunction.contains("deadline: .now() + narrowScanFallbackDelay"),
                     "Narrow scan fallback should use the named timing policy")
        precondition(scanFunction.contains("deadline: .now() + broadScanTimeout"),
                     "Broad scan timeout should use the named timing policy")
        precondition(scanFunction.contains("connectRememberedPeripheralIfAvailable"),
                     "Pull scan should first try a remembered CoreBluetooth peripheral when available")
        precondition(pullClient.contains("central.retrievePeripherals(withIdentifiers: ids)"),
                     "Remembered watch fallback should use CoreBluetooth retrievePeripherals")
        precondition(pullClient.contains("pull retrieve remembered connect timeout"),
                     "Remembered watch fallback should time out and return to scan")
        precondition(pullClient.contains("pull remembered verified peripheral id="),
                     "Remembered watch IDs should be saved only after service characteristic verification")
        precondition(!scanFunction.contains("deadline: .now() + 5, execute: item"),
                     "Pull discovery should not keep the old five-second narrow scan delay")
        precondition(!scanFunction.contains("deadline: .now() + 8, execute: finalItem"),
                     "Pull discovery should not keep the old eight-second broad scan timeout")

        print("watch_scan_timing_contract_smoke passed")
    }
}
