import Foundation

actor SlowUploadProbe {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var uploadedNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        active += 1
        maxActive = max(maxActive, active)
        uploadedNames.append(filename)
        try await Task.sleep(nanoseconds: 120_000_000)
        active -= 1
        return "纪要 \(filename) \(contentType) \(data.count)"
    }
}

@main
struct QueueWhileActiveSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-queue-while-active-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = SlowUploadProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 9, count: 4096)
        let first = try await MainActor.run { () -> MeetingRecording in
            _ = try store.storeWatchAudio(audio, filename: "one.m4a", autoProcess: false)
            _ = try store.storeWatchAudio(audio, filename: "two.m4a", autoProcess: false)
            return try store.storeWatchAudio(audio, filename: "three.m4a", autoProcess: false)
        }

        await store.generateNotes(for: first)

        for _ in 0..<40 {
            let active = await MainActor.run { store.sendingID != nil }
            if active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let enqueued = await store.generatePendingNotes()
        precondition(enqueued == 2, "expected two newly queued recordings while one is active, saw \(enqueued)")

        let queuedSnapshot = await MainActor.run {
            (
                sendingID: store.sendingID,
                queued: store.queuedGenerationIDs,
                queuedItems: store.items.filter { store.queuedGenerationIDs.contains($0.id) },
                generateableCount: store.generateableCount
            )
        }

        precondition(queuedSnapshot.sendingID != nil, "expected active generation before queueing the rest")
        precondition(queuedSnapshot.queued.count == 2, "expected two queued recordings, saw \(queuedSnapshot.queued.count)")
        precondition(queuedSnapshot.generateableCount == 0, "queued recordings should leave no unqueued generateable items")
        precondition(queuedSnapshot.queuedItems.allSatisfy { $0.statusText.hasPrefix("已排队") },
                     "queued recordings should expose queued status immediately")

        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.allSatisfy { $0.state == .sent }
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let maxActive = await probe.maxActive
        let uploadedNames = await probe.uploadedNames
        let finalItems = await MainActor.run { store.items }

        precondition(maxActive == 1, "expected serial uploads, saw \(maxActive) concurrent uploads")
        precondition(uploadedNames.count == 3, "expected 3 uploads, saw \(uploadedNames.count)")
        precondition(finalItems.allSatisfy { $0.state == .sent }, "expected all recordings sent")

        print("queue_while_active_smoke passed: queued while active, uploaded=\(uploadedNames.joined(separator: ","))")
    }
}
