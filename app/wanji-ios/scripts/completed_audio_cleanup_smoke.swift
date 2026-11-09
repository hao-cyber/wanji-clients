import Foundation

actor CleanupProbe {
    private(set) var uploadedNames: [String] = []

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        uploadedNames.append(filename)
        return "纪要 \(filename)"
    }
}

@main
struct CompletedAudioCleanupSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-completed-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = CleanupProbe()
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

        let audio = Data(repeating: 5, count: 4096)
        let completed = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "completed.m4a", autoProcess: false)
        }
        _ = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "pending.m4a", autoProcess: false)
        }

        await store.generateNotes(for: completed)
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.contains { $0.originalName == "completed.m4a" && $0.state == .sent }
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let removed = await MainActor.run { store.deleteCompletedAudioKeepingNotes() }
        let finalItems = await MainActor.run { store.items }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)

        let completedFinal = finalItems.first { $0.originalName == "completed.m4a" }
        let pendingFinal = finalItems.first { $0.originalName == "pending.m4a" }

        precondition(removed == 1, "expected one completed audio cleanup, got \(removed)")
        precondition(finalItems.count == 2, "cleanup should preserve records")
        precondition(completedFinal?.state == .sent, "completed record should remain sent")
        precondition(completedFinal?.noteText.isEmpty == false, "completed note should remain")
        precondition(completedFinal?.audioRetained == false, "completed audio should be removed")
        precondition(pendingFinal?.audioRetained == true, "pending audio should remain")
        precondition(files.contains { $0.hasSuffix(".m4a") }, "pending audio file should remain on disk")

        print("completed_audio_cleanup_smoke passed")
    }
}
