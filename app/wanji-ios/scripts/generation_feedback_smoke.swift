import Foundation

actor GenerationFeedbackProbe {
    private(set) var uploadedNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        try await Task.sleep(nanoseconds: 250_000_000)
        uploadedNames.append(filename)
        return "纪要 \(filename)"
    }
}

@main
struct GenerationFeedbackSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-generation-feedback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = GenerationFeedbackProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 8, count: 4096)
        let item = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "retry.m4a", autoProcess: false)
        }

        await MainActor.run { store.errorText = "旧错误" }
        await store.generateNotes(for: item)

        let immediate = await MainActor.run {
            (
                error: store.errorText,
                active: store.sendingID == item.id || store.queuedGenerationIDs.contains(item.id)
            )
        }
        precondition(immediate.error == nil, "accepted generation should clear stale error immediately")
        precondition(immediate.active, "accepted generation should show active or queued state")

        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.contains { $0.id == item.id && $0.state == .sent }
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let final = await MainActor.run {
            store.items.first { $0.id == item.id }
        }
        let uploaded = await probe.uploadedNames
        precondition(final?.state == .sent, "generation should still complete")
        precondition(uploaded == ["retry.m4a"], "expected one upload, got \(uploaded)")

        print("generation_feedback_smoke passed")
    }
}
