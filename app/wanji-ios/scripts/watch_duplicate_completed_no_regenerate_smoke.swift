import Foundation

actor UploadCounter {
    private(set) var count = 0

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        count += 1
        return "纪要 \(filename) #\(count)"
    }
}

@main
struct WatchDuplicateCompletedNoRegenerateSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-duplicate-completed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let counter = UploadCounter()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                autoDeleteAudioAfterNotesProvider: { false },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(
                        transcript: "转写 \(filename)",
                        notes: try await counter.upload(data: data, filename: filename, contentType: contentType),
                        segments: []
                    )
                }
            )
        }

        let uploadID = "a1790000000000-77"
        let audio = Data(repeating: 4, count: 4096)
        let first = try await MainActor.run {
            try store.storeWatchAudio(audio,
                                      filename: "first.m4a",
                                      autoProcess: true,
                                      externalID: uploadID)
        }

        await store.generateNotesIfNeeded(for: first)
        try await waitUntilGenerated(store: store, id: first.id)

        let duplicate = try await MainActor.run {
            try store.storeWatchAudio(Data(repeating: 8, count: 8192),
                                      filename: "duplicate.m4a",
                                      autoProcess: true,
                                      externalID: uploadID)
        }
        await store.generateNotesIfNeeded(for: duplicate)
        try await Task.sleep(nanoseconds: 150_000_000)

        let final = await MainActor.run { store.items }
        let uploadCount = await counter.count

        precondition(duplicate.id == first.id, "duplicate uploadId should return completed existing item")
        precondition(final.count == 1, "duplicate completed upload should not add another record")
        precondition(final.first?.state == .sent, "existing completed item should remain sent")
        precondition(uploadCount == 1, "auto processing duplicate completed upload should not regenerate notes")

        print("watch_duplicate_completed_no_regenerate_smoke passed")
    }

    private static func waitUntilGenerated(store: RecordingStore, id: UUID) async throws {
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.contains { $0.id == id && $0.state == .sent }
            }
            if done { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("timed out waiting for generated notes")
    }
}
