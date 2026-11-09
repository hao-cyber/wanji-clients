import Foundation

@main
struct WatchSyncRequesterScanTimingSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let requester = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchSyncRequester.swift"),
                                   encoding: .utf8)
        guard let scanStart = requester.range(of: "private func scan(force: Bool"),
              let retryStart = requester.range(of: "@discardableResult", range: scanStart.upperBound..<requester.endIndex) else {
            preconditionFailure("Could not isolate Bluetooth sync requester scan function")
        }
        let scanFunction = String(requester[scanStart.lowerBound..<retryStart.lowerBound])

        precondition(requester.contains("private let narrowScanFallbackDelay: TimeInterval = 0.35"),
                     "Sync requester narrow scan should use the same fast fallback as pull discovery")
        precondition(requester.contains("private let broadScanTimeout: TimeInterval = 4.5"),
                     "Sync requester broad scan should use the same bounded timeout as pull discovery")
        precondition(scanFunction.contains("deadline: .now() + narrowScanFallbackDelay"),
                     "Sync requester narrow scan fallback should use the named policy")
        precondition(scanFunction.contains("deadline: .now() + broadScanTimeout"),
                     "Sync requester broad scan timeout should use the named policy")
        precondition(!scanFunction.contains("deadline: .now() + 5, execute: item"),
                     "Sync requester should not keep the old five-second narrow scan delay")
        precondition(!scanFunction.contains("deadline: .now() + 8, execute: finalItem"),
                     "Sync requester should not keep the old eight-second broad scan timeout")

        print("watch_sync_requester_scan_timing_smoke passed")
    }
}
