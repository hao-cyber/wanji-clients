import Foundation

@main
struct WatchNotifyPayloadThresholdSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)
        let advertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(advertiser.contains("STABLE_NOTIFY_PAYLOAD_BYTES = 192") &&
                     advertiser.contains("DEFAULT_NOTIFY_CREDIT_BYTES = STABLE_NOTIFY_PAYLOAD_BYTES * 16") &&
                     advertiser.contains("addManufacturerData(WANJI_MANUFACTURER_ID, WANJI_AD_MARKER)") &&
                     advertiser.contains("startAdvertising(advertiseSettings, advertiseData, advertiseCallback)") &&
                     !advertiser.contains("addServiceUuid(new ParcelUuid(WANJI_WATCH_SYNC_SERVICE_UUID))") &&
                     !advertiser.contains("scanResponseData") &&
                     advertiser.contains(#"String compact = "q:" + queuedShortId + ":" + item.sizeBytes"#) &&
                     advertiser.contains("richPayload.length <= maxReadPayloadBytes()") &&
                     advertiser.contains("watch pull merged queue meta compact fallback") &&
                     advertiser.contains("private String shortPullId(AudioItem item)") &&
                     advertiser.contains("watch pull merged short id resolved") &&
                     advertiser.contains(#"" notifyPayload=""#),
                     "Watch queue payload should stay inside the default ATT read payload while retaining stable notify payload sizing")
        precondition(ios.contains("let mtu: Int?") &&
                     ios.contains("let notifyPayload: Int?") &&
                     ios.contains("let externalID: String?") &&
                     ios.contains("case fullID = \"f\"") &&
                     ios.contains("text.hasPrefix(\"q:\")") &&
                     ios.contains("private func storageExternalID(for item: WatchPullQueueItem, body: Data)") &&
                     ios.contains("private let minEfficientNotifyPayloadBytes = 64") &&
                     ios.contains("private let notifyCreditWindowBytes = 24576"),
                     "iPhone queue model should decode JSON and compact queue payloads")
        precondition(ios.contains("notifyPayload < minEfficientNotifyPayloadBytes") &&
                     ios.contains("readOnlyTransfer = true") &&
                     ios.contains("pull notify payload too small") &&
                     ios.contains("notify: useNotifyStream"),
                     "iPhone should use read mode when notify payload is too small to be efficient")

        print("watch_notify_payload_threshold_smoke passed")
    }
}
