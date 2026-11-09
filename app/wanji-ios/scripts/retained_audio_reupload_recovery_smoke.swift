import Foundation

actor RetainedAudioReuploadProbe {
    private(set) var uploadedNames: [String] = []

    func upload(fileURL: URL,
                filename: String,
                contentType: String,
                onProgress: ((MeetingNotesAPI.JobProgress) -> Void)?) async throws -> MeetingNotesAPI.MeetingNotesResult {
        precondition(FileManager.default.fileExists(atPath: fileURL.path), "retained audio file should be uploaded from disk")
        uploadedNames.append(filename)
        try await Task.sleep(nanoseconds: 300_000_000)
        onProgress?(MeetingNotesAPI.JobProgress(jobId: "new-reupload-job", status: "queued", stage: "queued"))
        return MeetingNotesAPI.MeetingNotesResult(
            transcript: "重新上传后识别出的完整转写",
            notes: "重新上传后生成的纪要",
            segments: [TranscriptSegment(startMs: 0, endMs: 1800000, text: "重新上传后识别出的完整转写")],
            jobId: "new-reupload-job"
        )
    }
}

@main
struct RetainedAudioReuploadRecoverySmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-retained-reupload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let storedName = "retained-long.m4a"
        let audioURL = root.appendingPathComponent(storedName)
        try Data(repeating: 9, count: 4096).write(to: audioURL)

        let oldJobID = "old-empty-asr-job"
        let recording = MeetingRecording(
            id: UUID(),
            originalName: "watch-long.m4a",
            storedName: storedName,
            importedAt: Date(),
            byteCount: 4096,
            durationMs: 1_802_000,
            state: .failed,
            statusText: "本次重试未识别出文字，录音已保留，可重试",
            noteText: "",
            source: "watch",
            autoProcess: true,
            audioRetained: true,
            backendJobId: oldJobID,
            backendStage: "failed"
        )
        let manifest = try JSONEncoder().encode([recording])
        try manifest.write(to: root.appendingPathComponent("manifest.json"))

        let probe = RetainedAudioReuploadProbe()
        let store = await MainActor.run {
            RecordingStore(
                rootURL: root,
                backendStatusProvider: { .ready },
                autoDeleteAudioAfterNotesProvider: { false },
                fileNotesUploader: { fileURL, filename, contentType, _, onProgress in
                    try await probe.upload(fileURL: fileURL,
                                           filename: filename,
                                           contentType: contentType,
                                           onProgress: onProgress)
                }
            )
        }

        await MainActor.run { store.load() }

        var sawUploadingWithoutOldJob = false
        for _ in 0..<20 {
            let snapshot = await MainActor.run { store.items.first }
            if snapshot?.state == .sending {
                sawUploadingWithoutOldJob = snapshot?.backendJobId == nil
                    && snapshot?.backendStage == "uploading"
                    && snapshot?.statusText.contains("上传保留录音") == true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        for _ in 0..<100 {
            let done = await MainActor.run {
                store.sendingID == nil
                    && store.queuedGenerationIDs.isEmpty
                    && store.items.first?.state == .sent
            }
            if done { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let final = await MainActor.run { store.items.first }
        let uploaded = await probe.uploadedNames
        precondition(sawUploadingWithoutOldJob, "recovery should clear stale backendJobId and show upload state before polling")
        precondition(uploaded == ["watch-long.m4a"], "expected retained audio reupload, got \(uploaded)")
        precondition(final?.state == .sent, "reupload recovery should complete")
        precondition(final?.backendJobId == "new-reupload-job", "final job id should be the new upload job, got \(final?.backendJobId ?? "nil")")
        precondition(final?.transcriptText.contains("完整转写") == true, "transcript should be persisted")
        precondition(final?.noteText.contains("纪要") == true, "notes should be persisted")

        print("retained_audio_reupload_recovery_smoke passed")
    }
}
