import Foundation

actor UploadProbe {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var uploadedNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        active += 1
        maxActive = max(maxActive, active)
        uploadedNames.append(filename)
        try await Task.sleep(nanoseconds: 40_000_000)
        active -= 1
        return "纪要 \(filename) \(contentType) \(data.count)"
    }
}

@main
struct QueueSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-queue-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = UploadProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 7, count: 4096)
        try await MainActor.run {
            _ = try store.storeWatchAudio(audio, filename: "one.m4a", autoProcess: false)
            _ = try store.storeWatchAudio(audio, filename: "two.m4a", autoProcess: false)
            _ = try store.storeWatchAudio(audio, filename: "three.m4a", autoProcess: false)
        }

        let enqueued = await store.generatePendingNotes()
        precondition(enqueued == 3, "expected 3 newly enqueued recordings, saw \(enqueued)")

        let duplicateEnqueued = await store.generatePendingNotes()
        precondition(duplicateEnqueued == 0, "duplicate bulk generate should not enqueue again")

        let activeDeleteResult = await MainActor.run { () -> Bool in
            guard let active = store.items.first(where: { store.isActiveGeneration($0) }) else {
                return false
            }
            return store.delete(active)
        }
        precondition(activeDeleteResult == false, "active generation item should not be deletable")

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
        precondition(finalItems.allSatisfy { $0.state == .sent }, "expected all items sent: \(finalItems)")
        precondition(finalItems.allSatisfy { !$0.noteText.isEmpty }, "expected notes on all items")

        print("queue_smoke passed: uploaded=\(uploadedNames.joined(separator: ","))")
    }
}
