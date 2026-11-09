import Foundation

@main
struct WatchNotifyOffsetFrameSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)
        let advertiser = try String(contentsOf: root.deletingLastPathComponent()
            .appendingPathComponent("android-watch/app/src/main/java/com/haowang/wristnote/BluetoothWatchSyncAdvertiser.java"),
                                    encoding: .utf8)

        precondition(advertiser.contains("private static final int NOTIFY_HEADER_BYTES = 8") &&
                     advertiser.contains("private byte[] notifyFrame(int offset, byte[] payload)") &&
                     advertiser.contains("writeInt32(frame, 0, offset)") &&
                     advertiser.contains("writeInt32(frame, 4, payload.length)") &&
                     advertiser.contains("dataCharacteristic.setValue(frame)"),
                     "Android notify chunks should include offset and length before payload")
        precondition(advertiser.contains("effectiveMtu - 3 - NOTIFY_HEADER_BYTES"),
                     "Notify payload sizing should reserve room for the application header")
        precondition(ios.contains("private let notifyChunkHeaderBytes = 8") &&
                     ios.contains("private func decodedChunk(_ raw: Data, expected: Int) -> Data?") &&
                     ios.contains("guard shouldUseNotifyStream else { return raw }") &&
                     ios.contains("offset == currentOffset") &&
                     ios.contains("length == payloadCount") &&
                     ios.contains("recoverFromNotifyFrameMismatch"),
                     "iPhone should validate notify offset/length and leave read mode raw")
        precondition(ios.contains("readOnlyTransfer = true") &&
                     ios.contains(#"setStatus("校正手表录音位置", severity: .receiving"#) &&
                     ios.contains("requestChunk()"),
                     "Notify frame mismatch should still have a read correction path")

        print("watch_notify_offset_frame_smoke passed")
    }
}
