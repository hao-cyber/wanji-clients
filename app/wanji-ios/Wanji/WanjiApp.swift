import SwiftUI
import Foundation

@main
struct WanjiApp: App {
    init() {
        UserDefaults.standard.register(defaults: [:])
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        Self.debugLog("app init bundle=\(bundleID) build=\(build)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private static func debugLog(_ message: String) {
        let line = "[WanjiBLE] \(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        print(line, terminator: "")
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("wanji-ble.log") else {
            return
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
}
