import Foundation

actor StaleErrorProbe {
    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        "纪要 \(filename)"
    }
}

@main
struct StaleErrorRecoverySmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-stale-error-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = StaleErrorProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                autoDeleteAudioAfterNotesProvider: { false },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 7, count: 4096)
        let pending = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "pending.m4a", autoProcess: false)
        }

        await MainActor.run { store.errorText = "旧错误" }
        let deleted = await MainActor.run { store.delete(pending) }
        let deleteError = await MainActor.run { store.errorText }
        precondition(deleted, "delete should succeed")
        precondition(deleteError == nil, "successful delete should clear stale error")

        let completed = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "completed.m4a", autoProcess: false)
        }
        await store.generateNotes(for: completed)
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.contains { $0.id == completed.id && $0.state == .sent }
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await MainActor.run { store.errorText = "旧错误" }
        let removed = await MainActor.run { store.deleteCompletedAudioKeepingNotes() }
        let cleanupError = await MainActor.run { store.errorText }
        precondition(removed == 1, "completed audio cleanup should remove one audio")
        precondition(cleanupError == nil, "successful completed-audio cleanup should clear stale error")

        _ = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "one-more.m4a", autoProcess: false)
        }
        await MainActor.run { store.errorText = "旧错误" }
        let cleared = await MainActor.run { store.deleteAllLocalRecordings() }
        let clearAllError = await MainActor.run { store.errorText }
        precondition(cleared, "clear all should succeed")
        precondition(clearAllError == nil, "successful clear all should clear stale error")

        print("stale_error_recovery_smoke passed")
    }
}
