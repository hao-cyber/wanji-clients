import Foundation

@main
struct WatchNotifyRetryContractSmoke {
    static func main() throws {
        let wanjiRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repoAppRoot = wanjiRoot.deletingLastPathComponent()
        let advertiser = try String(
            contentsOf: repoAppRoot.appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
            encoding: .utf8
        )

        precondition(advertiser.contains("MAX_NOTIFY_RETRIES = 3"),
                     "Android watch should retry transient BLE notify failures before falling back to phone-side recovery")
        precondition(advertiser.contains("NOTIFY_RETRY_DELAY_MS = 35"),
                     "Notify retry should be short enough to avoid an 8-second phone watchdog stall")
        precondition(advertiser.contains("retryNotifyChunk(start, \"queue_rejected\")"),
                     "Rejected notify queue attempts should retry the same offset instead of stopping the stream")
        precondition(advertiser.contains("retryNotifyChunk(lastNotifyStart, \"sent_status_\" + status)"),
                     "Failed notification delivery should rewind to the same chunk before retrying")
        precondition(advertiser.contains("selectedOffset = end;") &&
                     advertiser.contains("if (queued)"),
                     "Watch should only advance selectedOffset after the notification is queued")
        precondition(!advertiser.contains("if (queued) {\n            selectedOffset = end;\n            lastNotifyStart = start;\n            lastNotifyEnd = end;\n            notifyRetryCount = 0;"),
                     "Notify retry count should only reset after a successful delivery callback")
        precondition(advertiser.contains("notifyCreditEnd") &&
                     advertiser.contains("watch pull merged notify credit exhausted") &&
                     advertiser.contains("selectedOffset >= notifyCreditEnd"),
                     "The notify pump should be bounded by iPhone credit instead of streaming indefinitely")
        precondition(!advertiser.contains("scheduleNotifyNextChunk(10);"),
                     "The old fixed 10ms notify startup delay should stay removed")

        print("watch_notify_retry_contract_smoke passed")
    }
}
