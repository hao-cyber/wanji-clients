import Foundation

actor SingleCleanupProbe {
    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        "纪要 \(filename)"
    }
}

@main
struct SingleAudioCleanupSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-single-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = SingleCleanupProbe()
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

        let audio = Data(repeating: 3, count: 4096)
        let item = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "one-done.m4a", autoProcess: false)
        }

        await store.generateNotes(for: item)
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.first?.state == .sent
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let completed = await MainActor.run { store.items[0] }
        let firstRemoved = await MainActor.run {
            store.deleteCompletedAudioKeepingNotes(for: completed)
        }
        let afterCleanup = await MainActor.run { store.items[0] }
        let secondRemoved = await MainActor.run {
            store.deleteCompletedAudioKeepingNotes(for: afterCleanup)
        }

        precondition(firstRemoved == true, "expected first cleanup to remove audio")
        precondition(afterCleanup.state == .sent, "record should remain sent")
        precondition(afterCleanup.noteText.isEmpty == false, "note should remain")
        precondition(afterCleanup.audioRetained == false, "audio should be marked removed")
        precondition(secondRemoved == false, "second cleanup should be a no-op")
        precondition(afterCleanup.formattedSize == "原音频已移除", "expected removed audio size label")

        print("single_audio_cleanup_smoke passed")
    }
}
