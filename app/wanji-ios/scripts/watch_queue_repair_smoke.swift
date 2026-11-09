import Foundation

@main
struct WatchQueueRepairSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let watchRoot = root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote")
        let advertiser = try String(contentsOf: watchRoot.appendingPathComponent("BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)
        let store = try String(contentsOf: watchRoot.appendingPathComponent("AudioStore.java"),
                               encoding: .utf8)

        precondition(store.contains("boolean hasStoredAudio(AudioItem item)") &&
                     store.contains("file.isFile() && file.length() > 0"),
                     "Watch store should expose a cheap encrypted-audio presence check")
        precondition(advertiser.contains(#"private static final String PULL_ERROR_MISSING_AUDIO = "ble_missing_audio""#),
                     "Queue repair should use a stable unrecoverable missing-audio marker")
        precondition(advertiser.contains(#"private static final String PULL_ERROR_UNREADABLE_AUDIO = "ble_unreadable_audio""#),
                     "Queue repair should use a stable unreadable-audio marker")
        precondition(advertiser.contains("private boolean isUnrecoverablePullError(AudioItem item)") &&
                     advertiser.contains("PULL_ERROR_UNREADABLE_AUDIO.equals(item.lastError)"),
                     "Queue selection should skip items already known to be unreadable")
        precondition(advertiser.contains("PULL_ERROR_MISSING_AUDIO.equals(item.lastError)") &&
                     advertiser.contains("!store.hasStoredAudio(item)") &&
                     advertiser.contains("watch pull merged queue skipped missing audio"),
                     "Pull queue should skip missing-audio records instead of blocking later recordings")
        precondition(advertiser.contains("private void markPullItemUnreadable(String id, Exception cause)") &&
                     advertiser.contains("item.lastError = PULL_ERROR_UNREADABLE_AUDIO") &&
                     advertiser.contains("store.saveOrThrow(items)") &&
                     advertiser.contains("watch pull merged marked unreadable id="),
                     "Control read/decrypt failures should mark the item so later queue reads can advance")
        precondition(advertiser.contains("item.state = AudioItem.FAILED") &&
                     advertiser.contains("item.lastError = PULL_ERROR_MISSING_AUDIO") &&
                     advertiser.contains("item.attempts++") &&
                     advertiser.contains("persistQueueRepair(items)"),
                     "Skipped queue records should be marked and persisted for diagnostics")
        precondition(advertiser.contains("watch pull merged build=") &&
                     advertiser.contains("service="),
                     "Watch BLE pull logs should identify the running protocol build")

        print("watch_queue_repair_smoke passed")
    }
}
