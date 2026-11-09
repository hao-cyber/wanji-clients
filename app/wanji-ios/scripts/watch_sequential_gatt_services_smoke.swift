import Foundation

@main
struct WatchSequentialGattServicesSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let advertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(advertiser.contains("private BluetoothGattService pendingPullService;") &&
                     advertiser.contains("pendingPullService = pullService;") &&
                     advertiser.contains("addPendingPullServiceIfNeeded();"),
                     "Watch should defer adding the pull service until the sync service callback succeeds")
        precondition(advertiser.contains("private void addPendingPullServiceIfNeeded()") &&
                     advertiser.contains("watch pull merged add pull service after sync service") &&
                     advertiser.contains("server.addService(service)"),
                     "Deferred pull service add should be explicit and logged")
        precondition(!advertiser.contains("if (!server.addService(pullService))"),
                     "Watch should not add sync and pull services back-to-back on devices that serialize GATT service registration")
        precondition(advertiser.contains("watch pull merged build=uuid4400-v89-no-idle-gatt-rebuild"),
                     "Watch BLE pull build tag should identify the sequential GATT service fix")
        precondition(!advertiser.contains(".addServiceUuid(new ParcelUuid(WANJI_WATCH_SYNC_SERVICE_UUID))"),
                     "Primary BLE advertisement should stay small and rely on the WANJI manufacturer marker")
        precondition(advertiser.contains("ADVERTISING_REFRESH_MS = 30_000") &&
                     advertiser.contains("watch sync advertiser refresh restart advertising only") &&
                     advertiser.contains("scheduleGattServerRebuild(\"post_disconnect\"") &&
                     advertiser.contains("if (notifyDevice != null || streaming)") &&
                     !advertiser.contains("watch sync advertiser refresh rebuilding stale idle connection"),
                     "Watch should not rebuild the GATT server while an iPhone connection can be discovering characteristics")

        print("watch_sequential_gatt_services_smoke passed")
    }
}
