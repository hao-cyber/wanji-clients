import Foundation

@main
struct WatchControlResponseRaceSmoke {
    static func main() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
        let iosRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
        let appRoot = iosRoot.deletingLastPathComponent()
        let pullClient = try String(contentsOf: iosRoot.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)
        let advertiser = try String(contentsOf: appRoot.appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(pullClient.contains("guard controlCharacteristic.properties.contains(.write) else") &&
                     pullClient.contains("let useNotifyStream = shouldUseNotifyStream") &&
                     pullClient.contains("let canWriteWithoutResponse = !useNotifyStream && controlCharacteristic.properties.contains(.writeWithoutResponse)") &&
                     pullClient.contains("? .withoutResponse\n            : .withResponse") &&
                     pullClient.contains("target.writeValue(data, for: controlCharacteristic, type: type)"),
                     "iPhone should use acknowledged control writes for notify mode while allowing read fallback to use writeWithoutResponse")
        precondition(pullClient.contains("if shouldUseNotifyStream {\n                debugLog(\"pull data notify active; waiting for stream offset=\\(currentOffset)\")\n            } else {\n                scheduleDataRead(after: 0.15)\n            }"),
                     "Notify mode should wait for the data stream after didWriteValueFor; read mode should schedule a read after acknowledged writes")
        precondition(pullClient.contains("if type == .withoutResponse, !useNotifyStream {\n            scheduleDataRead(after: 0.18)\n        }"),
                     "Write-without-response read fallback still needs an explicit data-read timer")
        precondition(advertiser.contains("PULL_CONTROL_UUID,\n                BluetoothGattCharacteristic.PROPERTY_WRITE\n                        | BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,\n                BluetoothGattCharacteristic.PERMISSION_WRITE"),
                     "Android watch should expose acknowledged writes plus write-without-response for read fallback compatibility")

        print("watch_control_response_race_smoke passed")
    }
}
