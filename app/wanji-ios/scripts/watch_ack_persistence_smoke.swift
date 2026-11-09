import Foundation

@main
struct WatchAckPersistenceSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let advertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)
        let store = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/AudioStore.java"),
                               encoding: .utf8)

        precondition(store.contains("void save(List<AudioItem> items)") &&
                     store.contains("void saveOrThrow(List<AudioItem> items) throws Exception"),
                     "AudioStore should expose both best-effort and throwing saves")
        precondition(advertiser.contains("watch pull merged build="),
                     "Watch BLE pull logs should identify the active build")
        precondition(advertiser.contains("store.saveOrThrow(items);"),
                     "BLE ACK should use the throwing save path")
        precondition(!advertiser.contains("item.syncKind = \"ble-pull\";\n                    store.save(items);"),
                     "BLE ACK must not report GATT success after a swallowed index-save failure")
        precondition(advertiser.contains("watch pull merged ack failed"),
                     "ACK persistence failures should be visible in watch logs and returned as GATT failure")

        print("watch_ack_persistence_smoke passed")
    }
}
