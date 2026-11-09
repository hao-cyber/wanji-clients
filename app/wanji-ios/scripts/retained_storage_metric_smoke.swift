import Foundation

@main
struct RetainedStorageMetricSmoke {
    static func main() {
        let retained = MeetingRecording(
            id: UUID(),
            originalName: "retained.m4a",
            storedName: "retained.m4a",
            importedAt: Date(),
            byteCount: 4096,
            state: .local,
            statusText: "已保存在本机",
            noteText: "",
            source: "watch",
            autoProcess: false,
            audioRetained: true
        )
        let removedWithStaleSize = MeetingRecording(
            id: UUID(),
            originalName: "removed.m4a",
            storedName: "removed.m4a",
            importedAt: Date(),
            byteCount: 8192,
            state: .sent,
            statusText: "纪要已生成，原始录音已从本机移除",
            noteText: "纪要",
            source: "watch",
            autoProcess: false,
            audioRetained: false
        )

        let total = RecordingStore.retainedAudioBytes(in: [retained, removedWithStaleSize])
        precondition(total == 4096, "removed audio must not contribute to retained storage; got \(total)")

        print("retained_storage_metric_smoke passed")
    }
}
