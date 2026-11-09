import Foundation

actor RetentionProbe {
    private(set) var uploaded = 0

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        uploaded += 1
        return "纪要 \(filename) \(contentType) \(data.count)"
    }
}

@main
struct RetentionSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-retention-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = RetentionProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                autoDeleteAudioAfterNotesProvider: { true },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(
                        transcript: "转写 \(filename)",
                        notes: try await probe.upload(data: data, filename: filename, contentType: contentType),
                        segments: [TranscriptSegment(startMs: 0, endMs: 1000, text: "转写 \(filename)")]
                    )
                }
            )
        }

        let audio = Data(repeating: 9, count: 4096)
        let item = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "sensitive.m4a", autoProcess: false)
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

        let afterFirstRun = await MainActor.run { store.items[0] }
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let uploadCount = await probe.uploaded

        precondition(uploadCount == 1, "expected one upload, saw \(uploadCount)")
        precondition(afterFirstRun.state == .sent, "expected sent state")
        precondition(afterFirstRun.audioRetained == true, "expected original audio retained for sentence playback")
        precondition(afterFirstRun.byteCount == audio.count, "expected retained byte count to remain")
        precondition(files.contains { $0.hasSuffix(".m4a") }, "expected retained audio file: \(files)")

        await store.generateNotes(for: afterFirstRun)
        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let finalUploadCount = await probe.uploaded
        let finalError = await MainActor.run { store.errorText ?? "" }
        precondition(finalUploadCount == 2, "retained audio should allow regeneration")
        precondition(finalError.isEmpty, "expected no removed-audio error, got \(finalError)")

        print("retention_smoke passed")
    }
}
