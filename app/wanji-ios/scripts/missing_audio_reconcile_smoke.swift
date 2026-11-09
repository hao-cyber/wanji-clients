import Foundation

actor MissingAudioProbe {
    private(set) var uploaded = 0

    func upload(data: Data, filename: String, contentType: String) async throws -> String {
        uploaded += 1
        return "纪要 \(filename) \(contentType) \(data.count)"
    }
}

@main
struct MissingAudioReconcileSmoke {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("wanji-missing-audio-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let probe = MissingAudioProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        let audio = Data(repeating: 5, count: 4096)
        let pending = try await MainActor.run {
            try store.storeWatchAudio(audio, filename: "pending.m4a", autoProcess: false)
        }
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

        try fm.removeItem(at: root.appendingPathComponent(pending.storedName))
        try fm.removeItem(at: root.appendingPathComponent(completed.storedName))

        let reloaded = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                notesUploader: { data, filename, contentType, _, _ in
                    MeetingNotesAPI.MeetingNotesResult(transcript: "转写 \(filename)", notes: try await probe.upload(data: data, filename: filename, contentType: contentType), segments: [])
                }
            )
        }

        await MainActor.run { reloaded.load() }

        let completedAfterLoad = await MainActor.run {
            reloaded.items.first { $0.id == completed.id }
        }
        let pendingAfterLoad = await MainActor.run {
            reloaded.items.first { $0.id == pending.id }
        }

        precondition(completedAfterLoad?.state == .sent, "completed note should remain sent")
        precondition(completedAfterLoad?.audioRetained == false, "completed missing audio should be marked removed")
        precondition(completedAfterLoad?.byteCount == 0, "completed missing audio byte count should be cleared")
        precondition(completedAfterLoad?.noteText.isEmpty == false, "completed note text should be retained")
        precondition(completedAfterLoad?.formattedSize == "原音频已移除", "expected removed audio size label")
        precondition(completedAfterLoad?.statusText.contains("文件缺失") == true, "completed status should explain missing audio")

        precondition(pendingAfterLoad?.state == .failed, "pending missing audio should become failed")
        precondition(pendingAfterLoad?.audioRetained == false, "pending missing audio should be marked removed")
        precondition(pendingAfterLoad?.byteCount == 0, "pending missing audio byte count should be cleared")
        precondition(pendingAfterLoad?.statusText.contains("文件缺失") == true, "pending status should explain missing audio")
        let countsAfterLoad = await MainActor.run {
            (
                pending: reloaded.pendingCount,
                generateable: reloaded.generateableCount,
                completed: reloaded.completedCount,
                completedAudioRetained: reloaded.completedAudioRetainedCount,
                unavailable: reloaded.unavailableCount
            )
        }
        precondition(countsAfterLoad.pending == 0, "missing audio should not count as pending")
        precondition(countsAfterLoad.generateable == 0, "missing audio should not be generateable")
        precondition(countsAfterLoad.completed == 1, "completed note should still count as completed")
        precondition(countsAfterLoad.completedAudioRetained == 0, "completed missing audio should not count as retained")
        precondition(countsAfterLoad.unavailable == 1, "only failed missing audio should count as unavailable")

        await reloaded.generatePendingNotes()
        try await Task.sleep(nanoseconds: 100_000_000)

        let uploaded = await probe.uploaded
        precondition(uploaded == 1, "missing audio should not be uploaded again; uploaded \(uploaded)")

        print("missing_audio_reconcile_smoke passed")
    }
}
