import Foundation
import Combine
import UniformTypeIdentifiers
import AVFoundation

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var startMs: Int64
    var endMs: Int64
    var text: String

    var startSeconds: TimeInterval {
        TimeInterval(max(0, startMs)) / 1000.0
    }

    var timeText: String {
        MeetingRecording.formatPlaybackTime(startSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case id, startMs, endMs, text
        case start_ms, end_ms
    }

    init(id: UUID = UUID(), startMs: Int64, endMs: Int64, text: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startMs = try c.decodeIfPresent(Int64.self, forKey: .startMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .start_ms)
            ?? 0
        endMs = try c.decodeIfPresent(Int64.self, forKey: .endMs)
            ?? c.decodeIfPresent(Int64.self, forKey: .end_ms)
            ?? startMs
        text = try c.decode(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startMs, forKey: .startMs)
        try c.encode(endMs, forKey: .endMs)
        try c.encode(text, forKey: .text)
    }
}

struct MeetingRecording: Identifiable, Codable, Equatable {
    enum StateValue: String, Codable {
        case local
        case sending
        case sent
        case failed
    }

    let id: UUID
    var originalName: String
    var storedName: String
    var importedAt: Date
    var byteCount: Int64
    var durationMs: Int64
    var state: StateValue
    var statusText: String
    var noteText: String
    var transcriptText: String
    var transcriptSegments: [TranscriptSegment]
    var source: String
    var autoProcess: Bool
    var audioRetained: Bool
    var externalID: String?
    var backendJobId: String?
    var backendStage: String?

    var formattedSize: String {
        guard audioRetained else { return "原音频已移除" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var recordedTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(importedAt) {
            formatter.dateFormat = "今天 HH:mm"
        } else if Calendar.current.isDateInYesterday(importedAt) {
            formatter.dateFormat = "昨天 HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: importedAt)
    }

    var durationText: String {
        Self.formatDuration(durationMs)
    }

    var displayTitle: String {
        durationMs > 0 ? "\(recordedTimeText) · \(durationText)" : recordedTimeText
    }

    var sourceText: String {
        source == "watch" ? "手表录音" : "本机导入"
    }

    enum CodingKeys: String, CodingKey {
        case id, originalName, storedName, importedAt, byteCount, durationMs, state, statusText, noteText, transcriptText, transcriptSegments, source, autoProcess, audioRetained, externalID, backendJobId, backendStage
    }

    init(id: UUID, originalName: String, storedName: String, importedAt: Date,
         byteCount: Int64, durationMs: Int64 = 0, state: StateValue, statusText: String, noteText: String,
         transcriptText: String = "", transcriptSegments: [TranscriptSegment] = [],
         source: String, autoProcess: Bool, audioRetained: Bool = true, externalID: String? = nil,
         backendJobId: String? = nil, backendStage: String? = nil) {
        self.id = id
        self.originalName = originalName
        self.storedName = storedName
        self.importedAt = importedAt
        self.byteCount = byteCount
        self.durationMs = durationMs
        self.state = state
        self.statusText = statusText
        self.noteText = noteText
        self.transcriptText = transcriptText
        self.transcriptSegments = transcriptSegments
        self.source = source
        self.autoProcess = autoProcess
        self.audioRetained = audioRetained
        self.externalID = externalID
        self.backendJobId = backendJobId
        self.backendStage = backendStage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        originalName = try c.decode(String.self, forKey: .originalName)
        storedName = try c.decode(String.self, forKey: .storedName)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        byteCount = try c.decode(Int64.self, forKey: .byteCount)
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs) ?? 0
        state = try c.decode(StateValue.self, forKey: .state)
        statusText = try c.decode(String.self, forKey: .statusText)
        noteText = try c.decode(String.self, forKey: .noteText)
        transcriptText = try c.decodeIfPresent(String.self, forKey: .transcriptText) ?? ""
        transcriptSegments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "file"
        autoProcess = try c.decodeIfPresent(Bool.self, forKey: .autoProcess) ?? false
        audioRetained = try c.decodeIfPresent(Bool.self, forKey: .audioRetained) ?? true
        externalID = try c.decodeIfPresent(String.self, forKey: .externalID)
        backendJobId = try c.decodeIfPresent(String.self, forKey: .backendJobId)
        backendStage = try c.decodeIfPresent(String.self, forKey: .backendStage)
    }

    static func formatDuration(_ durationMs: Int64) -> String {
        guard durationMs > 0 else { return "时长未知" }
        let totalSeconds = max(1, Int((Double(durationMs) / 1000.0).rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)秒"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return seconds == 0 ? "\(minutes)分" : "\(minutes)分\(seconds)秒"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)小时" : "\(hours)小时\(remainingMinutes)分"
    }

    static func formatPlaybackTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct WatchAudioStoreResult: Equatable {
    let recording: MeetingRecording
    let inserted: Bool
}

struct WatchAudioIngestOutcome: Equatable {
    let storeResult: WatchAudioStoreResult
    let generationEnqueued: Bool
    let generationActive: Bool
    let watchMessage: String
}

struct ImportAudioResult: Equatable {
    let importedCount: Int
    let failedCount: Int

    var hasFailures: Bool { failedCount > 0 }
}

@MainActor
final class RecordingStore: ObservableObject {
    typealias BackendStatusProvider = () -> MeetingNotesAPI.BackendStatus
    typealias NotesUploader = (Data, String, String, Int64, ((MeetingNotesAPI.JobProgress) -> Void)?) async throws -> MeetingNotesAPI.MeetingNotesResult
    typealias FileNotesUploader = (URL, String, String, Int64, ((MeetingNotesAPI.JobProgress) -> Void)?) async throws -> MeetingNotesAPI.MeetingNotesResult
    typealias AutoDeleteAudioAfterNotesProvider = () -> Bool
    typealias FileRemover = (URL) throws -> Void

    private enum StoreError: LocalizedError {
        case missingAudio
        case unsupportedImport
        case importedAudioTooSmall
        case corruptWatchAudio

        var errorDescription: String? {
            switch self {
            case .missingAudio:
                return "原始录音文件缺失，无法生成完整转写。"
            case .unsupportedImport:
                return "不支持导入文件夹。"
            case .importedAudioTooSmall:
                return "音频文件太小。"
            case .corruptWatchAudio:
                return "手表录音封装损坏，无法播放。"
            }
        }
    }

    @Published private(set) var items: [MeetingRecording] = []
    @Published private(set) var importing = false
    @Published private(set) var sendingID: UUID?
    @Published private(set) var queuedGenerationIDs: [UUID] = []
    @Published var errorText: String?

    private static let minimumAudioBytes = 2_000

    var hasActiveGeneration: Bool {
        sendingID != nil || !queuedGenerationIDs.isEmpty
    }

    var pendingCount: Int {
        items.filter {
            guard $0.audioRetained else { return false }
            return $0.state == .local || $0.state == .failed || $0.state == .sending
        }.count
    }

    var generateableCount: Int {
        items.filter {
            $0.audioRetained
                && ($0.state == .local || $0.state == .failed)
                && !queuedGenerationIDs.contains($0.id)
        }.count
    }

    var completedCount: Int {
        items.filter { $0.state == .sent }.count
    }

    var completedAudioRetainedCount: Int {
        items.filter { $0.state == .sent && $0.audioRetained }.count
    }

    var unavailableCount: Int {
        items.filter { !$0.audioRetained && $0.state != .sent }.count
    }

    var totalSizeText: String {
        ByteCountFormatter.string(fromByteCount: totalAudioBytes, countStyle: .file)
    }

    var totalAudioBytes: Int64 {
        Self.retainedAudioBytes(in: items)
    }

    static func retainedAudioBytes(in items: [MeetingRecording]) -> Int64 {
        items.reduce(Int64(0)) { total, item in
            total + (item.audioRetained ? item.byteCount : 0)
        }
    }

    private let fm = FileManager.default
    private let rootOverride: URL?
    private let backendStatusProvider: BackendStatusProvider
    private let fileNotesUploader: FileNotesUploader
    private let autoDeleteAudioAfterNotesProvider: AutoDeleteAudioAfterNotesProvider
    private let fileRemover: FileRemover
    private var generationTask: Task<Void, Never>?
    private var generationTaskID: UUID?
    private var generationRunTokens: [UUID: UUID] = [:]
    private var cancelledGenerationIDs = Set<UUID>()
    private var root: URL {
        if let rootOverride { return rootOverride }
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecordings", isDirectory: true)
    }
    private var manifestURL: URL {
        root.appendingPathComponent("manifest.json")
    }

    init(rootURL: URL? = nil,
         backendStatusProvider: @escaping BackendStatusProvider = { MeetingNotesAPI.backendStatus() },
         autoDeleteAudioAfterNotesProvider: @escaping AutoDeleteAudioAfterNotesProvider = {
             UserDefaults.standard.bool(forKey: AppSettings.autoDeleteAudioAfterNotesKey)
         },
         fileRemover: @escaping FileRemover = { url in
             try FileManager.default.removeItem(at: url)
         },
         notesUploader: NotesUploader? = nil,
         fileNotesUploader: FileNotesUploader? = nil) {
        rootOverride = rootURL
        self.backendStatusProvider = backendStatusProvider
        self.autoDeleteAudioAfterNotesProvider = autoDeleteAudioAfterNotesProvider
        self.fileRemover = fileRemover
        if let fileNotesUploader {
            self.fileNotesUploader = fileNotesUploader
        } else if let notesUploader {
            self.fileNotesUploader = { fileURL, filename, contentType, durationMs, onProgress in
                let data = try Data(contentsOf: fileURL)
                return try await notesUploader(data, filename, contentType, durationMs, onProgress)
            }
        } else {
            self.fileNotesUploader = { fileURL, filename, contentType, durationMs, onProgress in
                try await MeetingNotesAPI.uploadForMeetingNotes(fileURL: fileURL,
                                                                filename: filename,
                                                                contentType: contentType,
                                                                durationMs: durationMs,
                                                                onProgress: onProgress)
            }
        }
    }

    func load() {
        do {
            try prepareProtectedStorage()
            guard fm.fileExists(atPath: manifestURL.path) else { return }
            try applyFileProtectionIfAvailable(to: manifestURL)
            let data = try Data(contentsOf: manifestURL)
            items = try JSONDecoder().decode([MeetingRecording].self, from: data)
            reconcilePersistedAudioStateAfterLaunch()
            protectRetainedAudioFiles()
            resumeRecoverableBackendJobsAfterLaunch()
        } catch {
            errorText = "录音列表加载失败：\(error.localizedDescription)"
        }
    }

    func audioURL(for item: MeetingRecording) -> URL {
        root.appendingPathComponent(item.storedName)
    }

    @discardableResult
    func importFiles(_ urls: [URL]) async -> ImportAudioResult {
        guard !urls.isEmpty else { return ImportAudioResult(importedCount: 0, failedCount: 0) }
        importing = true
        defer { importing = false }

        var importedCount = 0
        var failedCount = 0

        do {
            try prepareProtectedStorage()
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
            return ImportAudioResult(importedCount: 0, failedCount: urls.count)
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()

            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory != true else {
                    throw StoreError.unsupportedImport
                }
                let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                let storedName = "\(UUID().uuidString).\(ext)"
                let dest = root.appendingPathComponent(storedName)
                try fm.copyItem(at: url, to: dest)
                do {
                    try applyFileProtectionIfAvailable(to: dest)
                    let attrs = try fm.attributesOfItem(atPath: dest.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > Int64(Self.minimumAudioBytes) else {
                        try? fm.removeItem(at: dest)
                        throw StoreError.importedAudioTooSmall
                    }

                    insertSorted(
                        MeetingRecording(
                            id: UUID(),
                            originalName: url.lastPathComponent,
                            storedName: storedName,
                            importedAt: Date(),
                            byteCount: size,
                            durationMs: Self.audioDurationMs(at: dest),
                            state: .local,
                            statusText: "已保存在本机，等待完整转写",
                            noteText: "",
                            source: "file",
                            autoProcess: false),
                    )
                    importedCount += 1
                } catch {
                    try? fm.removeItem(at: dest)
                    throw error
                }
            } catch {
                failedCount += 1
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        if importedCount > 0 {
            save()
        }
        if failedCount > 0 {
            errorText = importedCount > 0
                ? "已导入 \(importedCount) 条，另有 \(failedCount) 条导入失败。"
                : "导入失败：无法读取所选音频。"
        } else {
            errorText = nil
        }
        return ImportAudioResult(importedCount: importedCount, failedCount: failedCount)
    }

    func storeWatchAudio(_ data: Data,
                         filename: String,
                         autoProcess: Bool,
                         recordedAt: Date = Date(),
                         durationMs: Int64? = nil,
                         externalID: String? = nil) throws -> MeetingRecording {
        try storeWatchAudioResult(data,
                                  filename: filename,
                                  autoProcess: autoProcess,
                                  recordedAt: recordedAt,
                                  durationMs: durationMs,
                                  externalID: externalID).recording
    }

    func storeWatchAudioResult(_ data: Data,
                               filename: String,
                               autoProcess: Bool,
                               recordedAt: Date = Date(),
                               durationMs: Int64? = nil,
                               externalID: String? = nil) throws -> WatchAudioStoreResult {
        try prepareProtectedStorage()
        let normalizedExternalID = Self.safeExternalID(externalID)
        let existingIndex = normalizedExternalID.flatMap { externalID in
            items.firstIndex { $0.source == "watch" && $0.externalID == externalID }
        }
        if let normalizedExternalID,
           let existingIndex,
           items[existingIndex].source == "watch",
           items[existingIndex].externalID == normalizedExternalID {
            let existingURL = root.appendingPathComponent(items[existingIndex].storedName)
            if items[existingIndex].audioRetained,
               fm.fileExists(atPath: existingURL.path) {
                errorText = nil
                return WatchAudioStoreResult(recording: items[existingIndex], inserted: false)
            }
        }
        let requestedName = Self.safeAudioFilename(filename)
        let detectedContainer = AudioContainerDetector.detect(data)
        if detectedContainer == .m4a, !AudioContainerDetector.isCompleteMP4(data) {
            print("[WanjiAudio] rejected corrupt watch m4a bytes=\(data.count) original=\(requestedName) head=\(AudioContainerDetector.headHex(data))")
            throw StoreError.corruptWatchAudio
        }
        let cleanName = Self.audioFilename(requestedName, matching: detectedContainer)
        let ext = Self.safeAudioExtension(for: cleanName)
        let storedName = "\(UUID().uuidString).\(ext)"
        let dest = root.appendingPathComponent(storedName)
        try data.write(to: dest, options: .atomic)
        try applyFileProtectionIfAvailable(to: dest)
        let resolvedDurationMs = durationMs.flatMap { $0 > 0 ? $0 : nil }
            ?? Self.audioDurationMs(at: dest)
        if detectedContainer != .unknown {
            print("[WanjiAudio] stored watch audio container=\(detectedContainer) bytes=\(data.count) original=\(requestedName) stored=\(storedName) head=\(AudioContainerDetector.headHex(data))")
        } else {
            print("[WanjiAudio] stored watch audio unknown container bytes=\(data.count) original=\(requestedName) stored=\(storedName) head=\(AudioContainerDetector.headHex(data))")
        }
        if let existingIndex {
            let previousURL = root.appendingPathComponent(items[existingIndex].storedName)
            if previousURL != dest, fm.fileExists(atPath: previousURL.path) {
                try? fileRemover(previousURL)
            }
            items[existingIndex].originalName = cleanName
            items[existingIndex].storedName = storedName
            items[existingIndex].importedAt = recordedAt
            items[existingIndex].byteCount = Int64(data.count)
            items[existingIndex].durationMs = resolvedDurationMs
            items[existingIndex].audioRetained = true
            items[existingIndex].externalID = normalizedExternalID
            if items[existingIndex].state == .sent, !items[existingIndex].noteText.isEmpty {
                items[existingIndex].statusText = "纪要已生成，原始录音已恢复"
            } else {
                items[existingIndex].state = .local
                items[existingIndex].statusText = autoProcess
                    ? "手表已传到手机，等待自动完整转写"
                    : "已保存在本机，等待完整转写"
            }
            let restoredID = items[existingIndex].id
            sortItemsByRecordedTime()
            save()
            errorText = nil
            return WatchAudioStoreResult(recording: items.first(where: { $0.id == restoredID }) ?? items[existingIndex],
                                         inserted: false)
        }
        let item = MeetingRecording(
            id: UUID(),
            originalName: cleanName,
            storedName: storedName,
            importedAt: recordedAt,
            byteCount: Int64(data.count),
            durationMs: resolvedDurationMs,
            state: .local,
            statusText: autoProcess ? "手表已传到手机，等待自动完整转写" : "已保存在本机，等待完整转写",
            noteText: "",
            source: "watch",
            autoProcess: autoProcess,
            externalID: normalizedExternalID)
        insertSorted(item)
        save()
        errorText = nil
        return WatchAudioStoreResult(recording: item, inserted: true)
    }

    func ingestWatchAudioFromWatch(_ data: Data,
                                      filename: String,
                                      recordedAt: Date = Date(),
                                      durationMs: Int64? = nil,
                                      externalID: String? = nil) throws -> WatchAudioIngestOutcome {
        let shouldAutoProcess = backendStatusProvider().isReady
        let result = try storeWatchAudioResult(data,
                                               filename: filename,
                                               autoProcess: shouldAutoProcess,
                                               recordedAt: recordedAt,
                                               durationMs: durationMs,
                                               externalID: externalID)
        let enqueued = shouldAutoProcess
            ? enqueueGeneration(id: result.recording.id, allowSent: false)
            : false
        let active = isActiveGeneration(result.recording)
        let message = Self.watchIngestMessage(for: result.recording,
                                                inserted: result.inserted,
                                                backendReady: shouldAutoProcess,
                                                generationEnqueued: enqueued,
                                                generationActive: active)
        return WatchAudioIngestOutcome(storeResult: result,
                                       generationEnqueued: enqueued,
                                       generationActive: active,
                                       watchMessage: message)
    }

    func generateNotes(for item: MeetingRecording) async {
        enqueueGeneration(id: item.id, allowSent: true)
    }

    @discardableResult
    func generateNotesIfNeeded(for item: MeetingRecording) async -> Bool {
        enqueueGeneration(id: item.id, allowSent: false)
    }

    @discardableResult
    func generatePendingNotes() async -> Int {
        let status = backendStatusProvider()
        guard status.isReady else {
            errorText = status.message
            return 0
        }

        let targetIDs = items
            .filter { ($0.state == .local || $0.state == .failed) && $0.audioRetained }
            .map(\.id)

        var enqueued = 0
        for id in targetIDs {
            if enqueueGeneration(id: id, allowSent: false) {
                enqueued += 1
            }
        }
        return enqueued
    }

    func isQueuedForGeneration(_ item: MeetingRecording) -> Bool {
        queuedGenerationIDs.contains(item.id)
    }

    func isActiveGeneration(_ item: MeetingRecording) -> Bool {
        sendingID == item.id || queuedGenerationIDs.contains(item.id)
    }

    @discardableResult
    func cancelGenerationQueue() -> Int {
        let activeID = sendingID
        let queuedIDs = queuedGenerationIDs
        let cancelledCount = (activeID == nil ? 0 : 1) + queuedIDs.count
        guard cancelledCount > 0 else {
            errorText = "没有正在生成的纪要。"
            return 0
        }

        if let activeID {
            cancelledGenerationIDs.insert(activeID)
            generationRunTokens.removeValue(forKey: activeID)
            if let index = items.firstIndex(where: { $0.id == activeID }) {
                items[index].state = .failed
                items[index].statusText = "生成已取消，可稍后重试"
            }
        }

        cancelledGenerationIDs.formUnion(queuedIDs)
        for id in queuedIDs {
            resetQueuedGenerationStatus(id: id)
        }
        queuedGenerationIDs.removeAll()
        sendingID = nil

        generationTask?.cancel()
        generationTask = nil
        generationTaskID = nil
        errorText = nil
        save()
        return cancelledCount
    }

    @discardableResult
    private func enqueueGeneration(id: UUID, allowSent: Bool) -> Bool {
        let status = backendStatusProvider()
        guard status.isReady else {
            errorText = status.message
            return false
        }

        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if !allowSent, items[index].state == .sent { return false }
        guard items[index].audioRetained else {
            errorText = "原始录音已从本机移除，不能重新生成完整转写。"
            return false
        }
        if sendingID == id || queuedGenerationIDs.contains(id) { return false }

        cancelledGenerationIDs.remove(id)
        queuedGenerationIDs.append(id)
        errorText = nil
        if sendingID != nil {
            items[index].statusText = "已排队，等待当前转写任务"
            save()
        }
        drainGenerationQueue()
        return true
    }

    private func drainGenerationQueue() {
        guard sendingID == nil else { return }

        while !queuedGenerationIDs.isEmpty {
            let nextID = queuedGenerationIDs.removeFirst()
            guard items.contains(where: { $0.id == nextID }) else { continue }
            sendingID = nextID
            let runToken = UUID()
            generationRunTokens[nextID] = runToken
            generationTaskID = nextID
            generationTask = Task { await runGeneration(id: nextID, runToken: runToken) }
            return
        }
    }

    private func runGeneration(id: UUID, runToken: UUID) async {
        guard generationRunTokens[id] == runToken else {
            return
        }
        guard sendingID == id else {
            drainGenerationQueue()
            return
        }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            sendingID = nil
            drainGenerationQueue()
            return
        }

        items[index].state = .sending
        items[index].backendJobId = nil
        items[index].backendStage = "uploading"
        items[index].statusText = items[index].durationMs >= 8 * 60 * 1000
            ? "正在上传保留录音到后端"
            : "正在上传录音到后端"
        save()

        do {
            let item = items[index]
            let audioURL = root.appendingPathComponent(item.storedName)
            guard fm.fileExists(atPath: audioURL.path) else {
                markMissingAudio(at: index)
                throw StoreError.missingAudio
            }
            let attrs = try fm.attributesOfItem(atPath: audioURL.path)
            let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? item.byteCount
            guard byteCount > Int64(Self.minimumAudioBytes) else {
                throw MeetingNotesAPI.SendError.network("音频文件太小")
            }
            let result = try await fileNotesUploader(audioURL,
                                                     item.originalName,
                                                     Self.contentType(for: item.originalName),
                                                     item.durationMs,
                                                     { [weak self] progress in
                                                         Task { @MainActor in
                                                             self?.applyBackendProgress(progress, to: id)
                                                         }
                                                     })
            try checkGenerationNotCancelled(id: id, runToken: runToken)

            if let current = items.firstIndex(where: { $0.id == id }) {
                items[current].state = .sent
                items[current].statusText = result.notes.isEmpty
                    ? "完整转写已完成，纪要未返回"
                    : "完整转写和纪要已完成，录音保留用于逐句播放"
                items[current].backendJobId = result.jobId ?? items[current].backendJobId
                items[current].backendStage = "done"
                items[current].noteText = result.notes.isEmpty
                    ? "服务器已完成转写，但没有返回纪要。"
                    : result.notes
                items[current].transcriptText = result.transcript
                items[current].transcriptSegments = result.segments
                errorText = nil
            }
        } catch is CancellationError {
            cancelledGenerationIDs.remove(id)
            if let current = items.firstIndex(where: { $0.id == id }),
               items[current].state == .sending {
                items[current].state = .failed
                items[current].statusText = "生成已取消，可稍后重试"
            }
            errorText = nil
        } catch StoreError.missingAudio {
            errorText = StoreError.missingAudio.errorDescription
        } catch {
            let failureText = Self.generationFailureStatusText(error)
            if let current = items.firstIndex(where: { $0.id == id }) {
                items[current].state = .failed
                items[current].backendStage = "failed"
                items[current].statusText = failureText
            }
            errorText = Self.localizedFailureReason(error)
        }

        if sendingID == id {
            sendingID = nil
        }
        if generationTaskID == id {
            generationTask = nil
            generationTaskID = nil
        }
        if generationRunTokens[id] == runToken {
            generationRunTokens.removeValue(forKey: id)
        }
        save()
        drainGenerationQueue()
    }

    private func applyBackendProgress(_ progress: MeetingNotesAPI.JobProgress, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .sending || items[index].state == .failed else { return }
        if !progress.jobId.isEmpty {
            items[index].backendJobId = progress.jobId
        }
        items[index].backendStage = progress.stage
        switch progress.stage {
        case "uploading":
            items[index].statusText = items[index].durationMs >= 8 * 60 * 1000
                ? "正在上传保留录音到后端"
                : "正在上传录音到后端"
        case "queued":
            items[index].statusText = items[index].durationMs >= 8 * 60 * 1000
                ? "长录音已上传，等待分段转写"
                : "录音已上传，等待转写"
        case "transcribing":
            items[index].statusText = "后端正在完整转写"
        case "notes_generating":
            items[index].statusText = "完整转写已完成，正在生成纪要"
        case "done":
            items[index].statusText = "完整转写和纪要已完成，本机录音仍保留"
        case "failed":
            items[index].statusText = "后端处理失败，可重试"
        default:
            items[index].statusText = "后端任务已提交，等待转写"
        }
        save()
    }

    private func checkGenerationNotCancelled(id: UUID, runToken: UUID) throws {
        if Task.isCancelled || cancelledGenerationIDs.contains(id) || generationRunTokens[id] != runToken {
            throw CancellationError()
        }
    }

    private func resetQueuedGenerationStatus(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .local || items[index].state == .failed else { return }
        if items[index].audioRetained {
            items[index].statusText = items[index].source == "watch"
                ? "已保存在本机，后端配置后可生成完整转写"
                : "已保存在本机，等待完整转写"
        } else {
            items[index].statusText = "原始录音已移除，不能重新生成完整转写"
        }
    }

    private static func generationFailureStatusText(_ error: Error) -> String {
        let reason = localizedFailureReason(error)
        if MeetingNotesAPI.isEmptyTranscriptMessage(reason) {
            return "本次重试未识别出文字，录音已保留，可重试"
        }
        return "生成失败：\(shortFailureReason(error))。可稍后重试"
    }

    private static func shortFailureReason(_ error: Error) -> String {
        let reason = localizedFailureReason(error)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return "请检查后端配置或网络" }
        if reason.count > 42 {
            return "\(reason.prefix(42))..."
        }
        return reason
    }

    private static func localizedFailureReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func watchIngestMessage(for recording: MeetingRecording,
                                             inserted: Bool,
                                             backendReady: Bool,
                                             generationEnqueued: Bool,
                                             generationActive: Bool) -> String {
        if inserted {
            guard backendReady else {
                return "收到 \(recording.displayTitle)，已保存在本机，配置后端后可生成完整转写"
            }
            if generationEnqueued || generationActive {
                return "收到 \(recording.displayTitle)，已加入转写队列"
            }
            return "收到 \(recording.displayTitle)，已保存在本机，可稍后重试生成"
        }

        guard backendReady else {
            return "\(recording.displayTitle) 已接收过，本机记录已保留"
        }
        if generationEnqueued || generationActive {
            return "\(recording.displayTitle) 已接收过，已在转写队列"
        }
        return "\(recording.displayTitle) 已接收过，不重复生成"
    }

    private func reconcilePersistedAudioStateAfterLaunch() {
        var changed = false
        for index in items.indices {
            if items[index].state == .sending {
                items[index].state = .failed
                if items[index].backendJobId?.isEmpty == false {
                    items[index].statusText = "上次生成中断，正在恢复后端任务"
                } else {
                    items[index].statusText = "上次上传中断，录音已保留，可重试"
                }
                changed = true
            } else if items[index].statusText.hasPrefix("已排队") {
                items[index].statusText = items[index].source == "watch"
                    ? "已保存在本机，等待完整转写"
                    : "已保存在本机，等待完整转写"
                changed = true
            }

            if !items[index].audioRetained {
                if items[index].byteCount != 0 {
                    items[index].byteCount = 0
                    changed = true
                }
                continue
            }

            let audioURL = root.appendingPathComponent(items[index].storedName)
            if !fm.fileExists(atPath: audioURL.path) {
                markMissingAudio(at: index)
                changed = true
            } else if isCorruptWatchM4A(items[index], at: audioURL) {
                markCorruptAudio(at: index, audioURL: audioURL)
                changed = true
            } else if items[index].durationMs <= 0 {
                let durationMs = Self.audioDurationMs(at: audioURL)
                if durationMs > 0 {
                    items[index].durationMs = durationMs
                    changed = true
                }
            }
        }
        let beforeSort = items.map(\.id)
        sortItemsByRecordedTime()
        if beforeSort != items.map(\.id) {
            changed = true
        }
        if changed { save() }
    }

    private func resumeRecoverableBackendJobsAfterLaunch() {
        guard backendStatusProvider().isReady else { return }
        let recoverableIDs = items
            .filter {
                $0.state == .failed
                    && $0.audioRetained
                    && $0.autoProcess
                    && (!($0.backendJobId ?? "").isEmpty || $0.durationMs >= 8 * 60 * 1000)
            }
            .map(\.id)
        guard !recoverableIDs.isEmpty else { return }
        for id in recoverableIDs {
            _ = enqueueGeneration(id: id, allowSent: false)
        }
    }

    private func insertSorted(_ item: MeetingRecording) {
        items.append(item)
        sortItemsByRecordedTime()
    }

    private func sortItemsByRecordedTime() {
        items.sort {
            if $0.importedAt == $1.importedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.importedAt > $1.importedAt
        }
    }

    private func markMissingAudio(at index: Int) {
        items[index].audioRetained = false
        items[index].byteCount = 0
        if items[index].state == .sent, !items[index].noteText.isEmpty {
            items[index].statusText = "纪要已生成，原始录音文件缺失"
        } else {
            items[index].state = .failed
            items[index].statusText = "原始录音文件缺失，无法生成完整转写"
        }
    }

    private func markCorruptAudio(at index: Int, audioURL: URL) {
        try? fileRemover(audioURL)
        items[index].audioRetained = false
        items[index].byteCount = 0
        items[index].state = .failed
        items[index].statusText = "手表录音封装损坏，无法播放"
    }

    private func isCorruptWatchM4A(_ item: MeetingRecording, at audioURL: URL) -> Bool {
        guard item.source == "watch", item.audioRetained else { return false }
        let ext = Self.safeAudioExtension(for: item.storedName)
        guard ext == "m4a" || ext == "mp4" else { return false }
        guard let data = try? Data(contentsOf: audioURL) else { return false }
        return AudioContainerDetector.detect(data) == .m4a
            && !AudioContainerDetector.isCompleteMP4(data)
    }

    private func removeAudioFileAfterNotes(at index: Int) -> Bool {
        let audioURL = root.appendingPathComponent(items[index].storedName)
        do {
            if fm.fileExists(atPath: audioURL.path) {
                try fileRemover(audioURL)
            }
            items[index].audioRetained = false
            items[index].byteCount = 0
            items[index].statusText = "纪要已生成，原始录音已从本机移除"
            return true
        } catch {
            items[index].statusText = "纪要已生成，但原始录音删除失败"
            errorText = "原始录音删除失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func delete(_ item: MeetingRecording) -> Bool {
        guard !isActiveGeneration(item) else {
            errorText = "这条录音正在生成，完成或失败后再删除。"
            return false
        }

        if item.audioRetained {
            let audioURL = root.appendingPathComponent(item.storedName)
            do {
                if fm.fileExists(atPath: audioURL.path) {
                    try fileRemover(audioURL)
                }
            } catch {
                errorText = "原始录音删除失败：\(error.localizedDescription)"
                return false
            }
        }

        queuedGenerationIDs.removeAll { $0 == item.id }
        items.removeAll { $0.id == item.id }
        save()
        errorText = nil
        return true
    }

    @discardableResult
    func deleteAllLocalRecordings() -> Bool {
        guard !hasActiveGeneration else {
            errorText = "正在生成，完成或失败后再清空本机录音。"
            return false
        }

        var keptItems: [MeetingRecording] = []
        var failedCount = 0
        for item in items {
            guard item.audioRetained else { continue }
            let audioURL = root.appendingPathComponent(item.storedName)
            guard fm.fileExists(atPath: audioURL.path) else { continue }
            do {
                try fileRemover(audioURL)
            } catch {
                keptItems.append(item)
                failedCount += 1
            }
        }

        queuedGenerationIDs.removeAll { id in !keptItems.contains { $0.id == id } }
        items = keptItems
        save()
        if failedCount > 0 {
            errorText = "有 \(failedCount) 条原始录音删除失败，已保留在列表中。"
            return false
        }
        errorText = nil
        return true
    }

    @discardableResult
    func deleteCompletedAudioKeepingNotes() -> Int {
        guard !hasActiveGeneration else {
            errorText = "正在生成，完成或失败后再清理已完成录音。"
            return 0
        }

        var removedCount = 0
        var failedCount = 0
        for index in items.indices {
            guard items[index].state == .sent, items[index].audioRetained else { continue }
            if removeAudioFileAfterNotes(at: index) {
                removedCount += 1
            } else {
                failedCount += 1
            }
        }
        if removedCount > 0 {
            save()
            if failedCount == 0 {
                errorText = nil
            }
        }
        return removedCount
    }

    @discardableResult
    func deleteCompletedAudioKeepingNotes(for item: MeetingRecording) -> Bool {
        guard !isActiveGeneration(item) else {
            errorText = "这条录音正在生成，完成或失败后再清理原音频。"
            return false
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              items[index].state == .sent,
              items[index].audioRetained else {
            return false
        }

        let removed = removeAudioFileAfterNotes(at: index)
        if removed {
            save()
            errorText = nil
        }
        return removed
    }

    private func save() {
        do {
            try prepareProtectedStorage()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: manifestURL, options: .atomic)
            try applyFileProtectionIfAvailable(to: manifestURL)
        } catch {
            errorText = "录音列表保存失败：\(error.localizedDescription)"
        }
    }

    private func prepareProtectedStorage() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try applyFileProtectionIfAvailable(to: root)
    }

    private static func audioDurationMs(at url: URL) -> Int64 {
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 1000).rounded())
    }

    private func protectRetainedAudioFiles() {
        for item in items where item.audioRetained {
            try? applyFileProtectionIfAvailable(to: root.appendingPathComponent(item.storedName))
        }
    }

    private func applyFileProtectionIfAvailable(to url: URL) throws {
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                             ofItemAtPath: url.path)
        #else
        _ = url
        #endif
    }

    private static func contentType(for filename: String) -> String {
        switch safeAudioExtension(for: filename) {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "amr": return "audio/amr"
        case "caf": return "audio/x-caf"
        case "opus": return "audio/opus"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "audio/mp4"
        }
    }

    private static func safeAudioFilename(_ filename: String) -> String {
        let fallback = "watch-\(Int(Date().timeIntervalSince1970)).m4a"
        var name = filename
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""

        name = name.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        name = name
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, name != ".", name != ".." else { return fallback }

        if name.count > 96 {
            let ext = safeAudioExtension(for: name)
            let base = name.split(separator: ".").dropLast().joined(separator: ".")
            let prefix = String(base.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
            name = "\(prefix.isEmpty ? "watch" : prefix).\(ext)"
        }

        return name
    }

    private static func safeExternalID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 96 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
        return trimmed
    }

    private static func safeAudioExtension(for filename: String) -> String {
        let ext = filename
            .lowercased()
            .split(separator: ".")
            .last
            .map(String.init) ?? "m4a"
        switch ext {
        case "m4a", "mp4", "aac", "wav", "mp3", "caf", "opus", "ogg", "webm", "amr":
            return ext
        default:
            return "m4a"
        }
    }

    private static func audioFilename(_ filename: String,
                                      matching container: DetectedAudioContainer) -> String {
        guard let detectedExtension = container.preferredExtension else {
            return filename
        }
        let currentExtension = safeAudioExtension(for: filename)
        guard currentExtension != detectedExtension else { return filename }
        let base = filename.split(separator: ".").dropLast().joined(separator: ".")
        let stem = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stem.isEmpty ? "watch" : stem).\(detectedExtension)"
    }
}
