import Foundation

@main
struct WatchAudioChecksumSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)
        let watchRoot = root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote")
        let item = try String(contentsOf: watchRoot.appendingPathComponent("AudioItem.java"),
                              encoding: .utf8)
        let store = try String(contentsOf: watchRoot.appendingPathComponent("AudioStore.java"),
                               encoding: .utf8)
        let advertiser = try String(contentsOf: watchRoot.appendingPathComponent("BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(item.contains("String sha256 = \"\"") &&
                     item.contains(#"o.put("sha256", sha256)"#) &&
                     item.contains(#"o.optString("sha256", "")"#),
                     "Watch queue metadata should persist audio SHA-256")
        precondition(store.contains("MessageDigest.getInstance(\"SHA-256\")") &&
                     store.contains("item.sha256 = sha256(plain)") &&
                     store.contains("item.sha256 = sha256(pending.audioFile)"),
                     "Watch should calculate SHA-256 when recordings enter the local queue")
        precondition(advertiser.contains(#"payload.put("sha256", item.sha256)"#),
                     "Watch pull queue should expose SHA-256 to the phone")
        precondition(ios.contains("import CryptoKit") &&
                     ios.contains("let sha256: String?") &&
                     ios.contains("verifyChecksum(for: body, expectedHex: item.sha256)") &&
                     ios.contains("private let maxChecksumRetries = 1") &&
                     ios.contains("retryChecksumMismatch(id: id)") &&
                     ios.contains(#"setStatus("录音校验未通过，重新接收", severity: .receiving, progress: 0)"#) &&
                     ios.contains("currentOffset = 0") &&
                     ios.contains("self.requestChunk()") &&
                     ios.contains(#"fail("手表录音校验失败")"#),
                     "iPhone should verify watch audio, retry once from offset zero, then fail instead of ACKing corrupt audio")
        precondition(ios.range(of: "ackItem(id: id, continueSyncing: true)")!.lowerBound >
                     ios.range(of: "verifyChecksum(for: body, expectedHex: item.sha256)")!.lowerBound,
                     "Checksum verification must happen before ACK")
        precondition(ios.range(of: #"fail("手表录音校验失败")"#)!.lowerBound >
                     ios.range(of: "retryChecksumMismatch(id: id)")!.lowerBound,
                     "Checksum retry should run before the terminal checksum failure")

        print("watch_audio_checksum_smoke passed")
    }
}
