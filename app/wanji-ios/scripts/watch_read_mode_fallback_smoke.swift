import Foundation

@main
struct WatchReadModeFallbackSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)
        let advertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(ios.contains("private var readOnlyTransfer = false") &&
                     ios.contains("private var shouldUseNotifyStream: Bool") &&
                     ios.contains("data.append(notify ? UInt8(ascii: \"n\") : UInt8(ascii: \"r\"))") &&
                     ios.contains("creditBytes: useNotifyStream ? notifyCreditWindowBytes : 0"),
                     "iPhone control payload should declare notify/read mode explicitly and credit notify windows")
        precondition(ios.contains("self.readOnlyTransfer = true") &&
                     ios.contains("pull notify silent fallback to read") &&
                     ios.contains(#"setStatus("手表录音流降级接收", severity: .receiving"#),
                     "Notify silent fallback should switch the current transfer into read-only mode")
        precondition(ios.contains("readOnlyTransfer = true") &&
                     ios.contains(#"setStatus("录音校验未通过，重新接收", severity: .receiving, progress: 0)"#),
                     "Checksum retry should restart as read-only instead of risking another notify/read race")
        precondition(ios.contains("let canWriteWithoutResponse = !useNotifyStream && controlCharacteristic.properties.contains(.writeWithoutResponse)") &&
                     ios.contains("if type == .withoutResponse, !useNotifyStream") &&
                     ios.contains("} else {\n                scheduleDataRead(after: 0.15)\n            }") &&
                     ios.contains("} else if !shouldUseNotifyStream {\n            scheduleNextChunk()") &&
                     ios.contains("let timeout = shouldUseNotifyStream\n            ? (currentOffset == 0 ? notifyFirstChunkTimeout : notifyQuietTimeout)\n            : readQuietTimeout"),
                     "Read-only mode should wait for acknowledged control writes before scheduling reads")

        precondition(advertiser.contains("request.readMode = bytes[0] == 'r'") &&
                     advertiser.contains("json.optString(\"m\", \"\")") &&
                     advertiser.contains("streaming = !readMode && notifyEnabled && notifyDevice != null") &&
                     advertiser.contains("watch pull merged control read mode"),
                     "Watch should suppress notify streaming when iPhone requests read mode")
        precondition(advertiser.contains("watch pull merged build="),
                     "Watch logs should identify the BLE pull build")

        print("watch_read_mode_fallback_smoke passed")
    }
}
