import Foundation

@main
struct GenerationFailureReasonPersistenceSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-generation-failure-reason-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { _, _, _, _, _ in
                    throw MeetingNotesAPI.SendError.http(401)
                }
            )
        }

        let audio = Data(repeating: 6, count: 4096)
        let item = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "token-fail.m4a", autoProcess: false)
        }

        await store.generateNotes(for: item)
        try await waitUntilFailure(store: store, id: item.id)

        let failed = await MainActor.run {
            store.items.first { $0.id == item.id }
        }
        let errorText = await MainActor.run { store.errorText ?? "" }
        precondition(failed?.state == .failed, "failed upload should mark item failed")
        precondition(failed?.statusText.contains("API Token 不正确") == true,
                     "row status should persist the actionable backend failure, got \(failed?.statusText ?? "nil")")
        precondition(errorText.contains("API Token 不正确"),
                     "global error should still expose the backend failure")

        let reloaded = await MainActor.run {
            let next = RecordingStore(rootURL: root, backendStatusProvider: { .ready })
            next.load()
            return next.items.first { $0.id == item.id }
        }
        precondition(reloaded?.statusText.contains("API Token 不正确") == true,
                     "failure reason should survive app relaunch")

        print("generation_failure_reason_persistence_smoke passed")
    }

    private static func waitUntilFailure(store: RecordingStore, id: UUID) async throws {
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.contains { $0.id == id && $0.state == .failed }
            }
            if done { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        preconditionFailure("timed out waiting for generation failure")
    }
}
