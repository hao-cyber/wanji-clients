import Foundation

actor WaitingUploadProbe {
    private(set) var startedNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        startedNames.append(filename)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return "不应完成"
    }
}

@main
struct WatchIngestReceiptSmoke {
    static func main() async throws {
        try await readyBackendAutoQueues()
        try await missingBackendKeepsLocal()
        print("watch_ingest_receipt_smoke passed")
    }

    private static func readyBackendAutoQueues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-ingest-receipt-ready-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = WaitingUploadProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 6, count: 4096)
        let uploadID = "a1790000000000-auto"
        let first = try await MainActor.run {
            try store.ingestWatchAudioFromWatch(audio,
                                                   filename: "auto.m4a",
                                                   externalID: uploadID)
        }

        precondition(first.storeResult.inserted, "first upload should insert a recording")
        precondition(first.generationEnqueued, "ready backend should enqueue the new recording")
        precondition(first.generationActive, "new upload should be active or queued immediately")
        precondition(first.watchMessage.contains("已加入转写队列"),
                     "receiver message should expose auto-transcript queueing")

        let duplicate = try await MainActor.run {
            try store.ingestWatchAudioFromWatch(Data(repeating: 9, count: 4096),
                                                   filename: "duplicate.m4a",
                                                   externalID: uploadID)
        }
        let snapshot = await MainActor.run {
            (
                count: store.items.count,
                active: store.hasActiveGeneration,
                cancelled: store.cancelGenerationQueue()
            )
        }

        precondition(!duplicate.storeResult.inserted, "duplicate uploadId should not insert")
        precondition(duplicate.watchMessage.contains("已在转写队列"),
                     "duplicate active upload should say it is already queued")
        precondition(snapshot.count == 1, "duplicate upload should keep a single local record")
        precondition(snapshot.active, "generation should still be active before cancellation")
        precondition(snapshot.cancelled == 1, "cleanup should cancel the active generation")
    }

    private static func missingBackendKeepsLocal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-ingest-receipt-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = await MainActor.run {
            RecordingStore(rootURL: root, backendStatusProvider: { .missingToken })
        }

        let outcome = try await MainActor.run {
            try store.ingestWatchAudioFromWatch(Data(repeating: 4, count: 4096),
                                                   filename: "local-only.m4a")
        }
        let snapshot = await MainActor.run {
            (
                count: store.items.count,
                active: store.hasActiveGeneration,
                pending: store.pendingCount
            )
        }

        precondition(outcome.storeResult.inserted, "missing backend should still store the upload")
        precondition(!outcome.generationEnqueued, "missing backend must not enqueue generation")
        precondition(!outcome.generationActive, "missing backend must not mark generation active")
        precondition(outcome.watchMessage.contains("配置后端后可生成完整转写"),
                     "receiver message should say the audio is local until backend is configured")
        precondition(snapshot.count == 1, "local-only upload should be visible in queue")
        precondition(snapshot.pending == 1, "local-only upload should remain pending")
        precondition(!snapshot.active, "local-only upload should not start generation")
    }
}
