import Foundation

@main
struct PhoneInitiatedWatchSyncSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appSettings = try String(contentsOf: root.appendingPathComponent("Wanji/AppSettings.swift"),
                                     encoding: .utf8)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)
        let androidAdvertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                           encoding: .utf8)
        let iosReadme = try String(contentsOf: root.appendingPathComponent("README.md"),
                                   encoding: .utf8)

        precondition(appSettings.contains("watchPullServiceUUID"),
                     "iOS settings should define the watch pull service")
        precondition(appSettings.contains("watchPullQueueCharacteristicUUID"),
                     "iOS settings should define the watch pull queue characteristic")
        precondition(appSettings.contains("watchPullControlCharacteristicUUID"),
                     "iOS settings should define the watch pull control characteristic")
        precondition(appSettings.contains("watchPullDataCharacteristicUUID"),
                     "iOS settings should define the watch pull data characteristic")
        precondition(appSettings.contains("watchPullAckCharacteristicUUID"),
                     "iOS settings should define the watch pull ACK characteristic")

        precondition(content.contains("@StateObject private var watchPullClient = BluetoothWatchPullClient()"),
                     "ContentView should own the iPhone pull client")
        precondition(content.contains("watchPullClient.start()\n                scheduleAutomaticWatchPull(reason: \"appear\")"),
                     "Opening the iPhone app should start the pull client and schedule automatic sync")
        precondition(content.contains("watchPullClient.start()\n                    scheduleAutomaticWatchPull(reason: \"active\")"),
                     "Returning to the foreground should restart automatic pull sync")
        precondition(content.contains("sync requester skipped on automatic path bound=true"),
                     "Bound automatic flow should skip the old sync-command requester")
        precondition(content.contains(#"watchPullClient.syncNow(reason: "manual_button")"#),
                     "Manual sync should use the same pull path")
        precondition(!content.contains("watchSyncRequester.requestSync(force: true)"),
                     "iPhone should not use the old phone-command upload path")

        precondition(pullClient.contains("CBCentralManager"),
                     "iPhone pull client should use CoreBluetooth central mode")
        precondition(pullClient.contains("private let discoveryUUID = CBUUID(string: AppSettings.watchSyncServiceUUID)"),
                     "iPhone should first discover the watch using the small sync advertisement")
        precondition(pullClient.contains("private let serviceUUID = CBUUID(string: AppSettings.watchPullServiceUUID)"),
                     "iPhone should connect to the pull service after discovery")
        precondition(pullClient.contains("central.scanForPeripherals(withServices: [discoveryUUID]"),
                     "iPhone should prefer a narrow scan before broad fallback")
        precondition(pullClient.contains("peripheral.discoverServices([serviceUUID])"),
                     "iPhone should discover the pull service")
        precondition(pullClient.contains("peripheral.discoverCharacteristics([queueUUID, controlUUID, dataUUID, ackUUID]"),
                     "iPhone should discover queue/control/data/ACK characteristics")
        precondition(pullClient.contains("peripheral.setNotifyValue(true, for: dataCharacteristic)"),
                     "iPhone should enable data notifications for faster transfer")
        precondition(pullClient.contains("peripheral.readValue(for: queueCharacteristic)"),
                     "iPhone should read the watch queue")
        precondition(pullClient.contains("target.writeValue(data, for: controlCharacteristic"),
                     "iPhone should request audio chunks through the control characteristic")
        precondition(pullClient.contains("target.writeValue(data, for: ackCharacteristic"),
                     "iPhone should ACK saved recordings back to the watch")
        precondition(pullClient.contains("pull ack continue on existing connection"),
                     "ACK flow should reuse the existing connection to pull the next recording")

        precondition(androidAdvertiser.contains("PULL_SERVICE_UUID"),
                     "Android watch should expose the pull service")
        precondition(androidAdvertiser.contains("PULL_QUEUE_UUID"),
                     "Android watch should expose the pull queue characteristic")
        precondition(androidAdvertiser.contains("PULL_CONTROL_UUID"),
                     "Android watch should expose the pull control characteristic")
        precondition(androidAdvertiser.contains("PULL_DATA_UUID"),
                     "Android watch should expose the pull data characteristic")
        precondition(androidAdvertiser.contains("PULL_ACK_UUID"),
                     "Android watch should expose the pull ACK characteristic")
        precondition(androidAdvertiser.contains("BluetoothGattCharacteristic.PROPERTY_NOTIFY"),
                     "Android watch data characteristic should support notify")
        precondition(androidAdvertiser.contains("MAX_CHUNK_BYTES = 512"),
                     "Android watch should use the larger transfer chunk cap")
        precondition(androidAdvertiser.contains("AdvertiseSettings.ADVERTISE_TX_POWER_HIGH"),
                     "Android watch should advertise with high TX power for discovery")
        precondition(androidAdvertiser.contains("handlePullAck"),
                     "Android watch should delete/advance queue entries only after iPhone ACK")

        precondition(iosReadme.contains("iPhone 主动拉取"),
                     "iOS README should document the pull-first sync model")
        precondition(iosReadme.contains("打开腕记 -> 自动查找已绑定手表 -> 读取手表录音队列 -> 拉取录音 -> 本机保存 -> ACK -> 继续下一条"),
                     "iOS README should document the current real sync sequence")
        precondition(!iosReadme.contains("查找手表 -> 连接手表 -> 读取手表服务 -> 唤起手表同步 -> 已通知手表同步"),
                     "iOS README should not document the obsolete sync-command sequence as current behavior")

        print("phone_initiated_watch_sync_smoke passed")
    }
}
