import Foundation

actor CancelUploadProbe {
    private(set) var startedNames: [String] = []
    private(set) var cancelledNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        startedNames.append(filename)
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            cancelledNames.append(filename)
            throw error
        }
        return "不应返回 \(filename)"
    }
}

@main
struct CancelGenerationQueueSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-cancel-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = CancelUploadProbe()
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
            _ = try store.storeWatchAudio(audio, filename: "cancel-one.m4a", autoProcess: false)
            _ = try store.storeWatchAudio(audio, filename: "cancel-two.m4a", autoProcess: false)
            _ = try store.storeWatchAudio(audio, filename: "cancel-three.m4a", autoProcess: false)
        }

        let enqueued = await store.generatePendingNotes()
        precondition(enqueued == 3, "expected 3 recordings enqueued, saw \(enqueued)")

        for _ in 0..<80 {
            let readyToCancel = await MainActor.run {
                store.sendingID != nil && store.queuedGenerationIDs.count == 2
            }
            if readyToCancel { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let cancelled = await MainActor.run {
            store.cancelGenerationQueue()
        }
        precondition(cancelled == 3, "expected to cancel active plus two queued recordings, saw \(cancelled)")

        let snapshot = await MainActor.run {
            (
                sendingID: store.sendingID,
                queuedIDs: store.queuedGenerationIDs,
                items: store.items,
                generateableCount: store.generateableCount,
                errorText: store.errorText
            )
        }

        precondition(snapshot.sendingID == nil, "active generation should clear immediately")
        precondition(snapshot.queuedIDs.isEmpty, "queued generation IDs should clear immediately")
        precondition(snapshot.items.count == 3, "cancel should keep all recordings")
        precondition(snapshot.items.contains { $0.statusText.contains("取消") },
                     "active recording should show canceled status")
        precondition(snapshot.items.allSatisfy { $0.state == .local || $0.state == .failed },
                     "cancel should leave recordings retryable")
        precondition(snapshot.items.allSatisfy { !$0.statusText.hasPrefix("已排队") },
                     "queued recordings should no longer look queued")
        precondition(snapshot.generateableCount == 3, "all recordings should be generateable again")
        precondition(snapshot.errorText == nil, "cancel should not leave an error")

        for _ in 0..<80 {
            let cancelledNames = await probe.cancelledNames
            if !cancelledNames.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let startedNames = await probe.startedNames
        let cancelledNames = await probe.cancelledNames
        let finalItems = await MainActor.run { store.items }
        precondition(startedNames.count == 1, "only the active upload should have started, saw \(startedNames)")
        precondition(cancelledNames.count == 1, "active upload should receive task cancellation")
        precondition(finalItems.allSatisfy { $0.state != .sent }, "canceled uploads must not mark recordings sent")

        print("cancel_generation_queue_smoke passed: cancelled=\(cancelled), active=\(startedNames.first ?? "-")")
    }
}
