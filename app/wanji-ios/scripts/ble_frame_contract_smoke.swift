import Foundation

@main
struct BLEFrameContractSmoke {
    static func main() throws {
        let appRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()

        let watchBluetooth = try String(contentsOf: appRoot.appendingPathComponent("harmony-watch/entry/src/main/ets/net/BluetoothUploader.ets"),
                                        encoding: .utf8)
        precondition(watchBluetooth.contains("const BLE_MAX_FRAME_BYTES = 160"),
                     "Harmony BLE sender should keep a conservative frame-size budget")
        precondition(watchBluetooth.contains("const BLE_MAX_PAYLOAD_BYTES = BLE_MAX_FRAME_BYTES - 1"),
                     "Harmony BLE sender should reserve one byte for frame type")
        precondition(watchBluetooth.contains("const BLE_CHUNK_BYTES = BLE_MAX_PAYLOAD_BYTES"),
                     "Audio chunks should never exceed the guarded payload size")
        precondition(watchBluetooth.contains("t: phoneToken"),
                     "BLE header should use the runtime-bound compact token key")
        precondition(!watchBluetooth.contains("Secrets.PHONE_TOKEN"),
                     "Harmony release must not compile a phone token into the app")
        precondition(watchBluetooth.contains("f: filename"),
                     "BLE header should use compact filename key")
        precondition(watchBluetooth.contains("c: createdAt > 0 ? Math.round(createdAt) : Date.now()"),
                     "BLE header should use compact createdAt key")
        precondition(watchBluetooth.contains("u: uploadId"),
                     "BLE header should use compact uploadId key")
        precondition(watchBluetooth.contains("s: audioBuf.byteLength"),
                     "BLE header should use compact size key")
        precondition(watchBluetooth.contains("if (body.byteLength > BLE_MAX_PAYLOAD_BYTES)"),
                     "BLE sender should fail before writing oversized frames")
        precondition(watchBluetooth.contains("蓝牙头信息过长，请重新生成较短 Token 后复制配置"),
                     "Oversized BLE header should have a recoverable user message")

        let iosBluetooth = try String(contentsOf: appRoot.appendingPathComponent("wanji-ios/Wanji/BluetoothWatchReceiver.swift"),
                                      encoding: .utf8)
        precondition(iosBluetooth.contains("private enum CompactCodingKeys"),
                     "iOS BLE receiver should decode compact headers")
        precondition(iosBluetooth.contains(#"case token = "t""#),
                     "iOS BLE receiver should map compact token key")
        precondition(iosBluetooth.contains(#"case filename = "f""#),
                     "iOS BLE receiver should map compact filename key")
        precondition(iosBluetooth.contains(#"case createdAt = "c""#),
                     "iOS BLE receiver should map compact createdAt key")
        precondition(iosBluetooth.contains(#"case uploadId = "u""#),
                     "iOS BLE receiver should map compact uploadId key")
        precondition(iosBluetooth.contains(#"case size = "s""#),
                     "iOS BLE receiver should map compact size key")
        precondition(iosBluetooth.contains("full.decodeIfPresent(String.self, forKey: .token)"),
                     "iOS BLE receiver should remain compatible with old full headers")

        print("ble_frame_contract_smoke passed")
    }
}
