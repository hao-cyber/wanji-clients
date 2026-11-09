import Foundation

enum DeleteProbeError: LocalizedError {
    case blocked

    var errorDescription: String? {
        "模拟文件删除失败"
    }
}

@main
struct DeleteFailureRetainsRecordSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-delete-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                autoDeleteAudioAfterNotesProvider: { false },
                fileRemover: { _ in throw DeleteProbeError.blocked }
            )
        }

        let audio = Data(repeating: 9, count: 4096)
        let item = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "sensitive.m4a", autoProcess: false)
        }

        await MainActor.run { store.errorText = "旧错误" }
        let deleted = await MainActor.run { store.delete(item) }
        let afterDelete = await MainActor.run { (store.items, store.errorText) }

        precondition(!deleted, "delete should fail when retained audio cannot be removed")
        precondition(afterDelete.0.contains { $0.id == item.id }, "failed delete should keep record visible")
        precondition(afterDelete.0.first { $0.id == item.id }?.audioRetained == true, "failed delete should keep audioRetained")
        precondition(afterDelete.1?.contains("原始录音删除失败") == true, "failed delete should show deletion error")

        let cleared = await MainActor.run { store.deleteAllLocalRecordings() }
        let afterClear = await MainActor.run { (store.items, store.errorText) }

        precondition(!cleared, "clear all should fail when retained audio cannot be removed")
        precondition(afterClear.0.contains { $0.id == item.id }, "failed clear all should keep record visible")
        precondition(afterClear.1?.contains("已保留在列表中") == true, "failed clear all should explain retained records")

        print("delete_failure_retains_record_smoke passed")
    }
}
