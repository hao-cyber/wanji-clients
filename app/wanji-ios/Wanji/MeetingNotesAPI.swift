import Foundation
import CryptoKit

struct CopyFeedback: Equatable {
    enum Severity: Equatable {
        case success
        case warning
    }

    let text: String
    let severity: Severity
}

enum MeetingNotesAPI {
    private static let uploadAcceptTimeoutNanoseconds: UInt64 = 240_000_000_000

    struct MeetingNotesResult: Equatable {
        let transcript: String
        let notes: String
        let segments: [TranscriptSegment]
        let jobId: String?

        init(transcript: String, notes: String, segments: [TranscriptSegment], jobId: String? = nil) {
            self.transcript = transcript
            self.notes = notes
            self.segments = segments
            self.jobId = jobId
        }
    }

    struct JobProgress: Equatable {
        let jobId: String
        let status: String
        let stage: String
    }

    private struct SegmentResponse: Decodable {
        let startMs: Int64
        let endMs: Int64
        let text: String

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
        }
    }

    private struct UploadResponse: Decodable {
        let text: String?
        let transcript: String?
        let notes: String?
        let segments: [SegmentResponse]?
        let timingSource: String?
        let audioDurationSeconds: Double?
        let timelineCoverage: Double?
        let segmentTextCoverage: Double?

        enum CodingKeys: String, CodingKey {
            case text
            case transcript
            case notes
            case segments
            case timingSource = "timing_source"
            case audioDurationSeconds = "audio_duration_seconds"
            case timelineCoverage = "timeline_coverage"
            case segmentTextCoverage = "segment_text_coverage"
        }
    }

    private struct JobAcceptedResponse: Decodable {
        let jobId: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case jobId = "job_id"
            case status
        }
    }

    private struct ResumableUploadInitRequest: Encodable {
        let mode: String
        let filename: String
        let contentType: String
        let sizeBytes: Int64
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case mode
            case filename
            case contentType = "content_type"
            case sizeBytes = "size_bytes"
            case sha256
        }
    }

    private struct ResumableUploadSession: Decodable {
        let uploadId: String
        let chunkBytes: Int
        let uploadedChunks: [Int]
        let completedJobId: String

        enum CodingKeys: String, CodingKey {
            case uploadId = "upload_id"
            case chunkBytes = "chunk_bytes"
            case uploadedChunks = "uploaded_chunks"
            case completedJobId = "completed_job_id"
        }
    }

    private struct ResumableUploadUnavailable: Error {}

    private struct JobStatusResponse: Decodable {
        let status: String
        let error: String?
        let stage: String?
        let text: String?
        let transcript: String?
        let notes: String?
        let segments: [SegmentResponse]?
        let timingSource: String?
        let audioDurationSeconds: Double?
        let timelineCoverage: Double?
        let segmentTextCoverage: Double?

        enum CodingKeys: String, CodingKey {
            case status
            case error
            case stage
            case text
            case transcript
            case notes
            case segments
            case timingSource = "timing_source"
            case audioDurationSeconds = "audio_duration_seconds"
            case timelineCoverage = "timeline_coverage"
            case segmentTextCoverage = "segment_text_coverage"
        }
    }

    enum BackendStatus: Equatable {
        case missingServer
        case missingToken
        case invalidURL
        case insecureURL
        case ready

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var title: String {
            switch self {
            case .ready: return "后端已配置"
            case .missingServer, .missingToken: return "后端未配置"
            case .invalidURL, .insecureURL: return "后端配置不可用"
            }
        }

        var message: String {
            switch self {
            case .ready:
                return "录音可上传到私有后端生成纪要"
            case .missingServer:
                return "请填写私有后端地址"
            case .missingToken:
                return "请填写 API Token"
            case .invalidURL:
                return "服务器地址需要包含 scheme 和域名，例如 https://api.example.com"
            case .insecureURL:
                return "服务器地址需要使用 HTTPS，本机调试可用 localhost"
            }
        }

        var systemImage: String {
            switch self {
            case .ready: return "checkmark.seal"
            case .missingServer, .missingToken: return "exclamationmark.triangle"
            case .invalidURL, .insecureURL: return "lock.trianglebadge.exclamationmark"
            }
        }
    }

    enum SendError: Error, LocalizedError {
        case notConfigured
        case invalidURL
        case insecureURL
        case http(Int)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "请先在设置里填写服务器地址和 API Token"
            case .invalidURL:
                return "服务器地址格式不正确"
            case .insecureURL:
                return "服务器地址需要使用 HTTPS，本机调试可用 localhost"
            case .http(401):
                return "API Token 不正确（401）"
            case .http(499):
                return "上传中断，录音已保留，可重试"
            case .http(let code):
                return "服务器返回 \(code)"
            case .network(let message):
                return "连接服务器失败：\(message)"
            }
        }
    }

    static func backendStatus() -> BackendStatus {
        let base = (UserDefaults.standard.string(forKey: AppSettings.serverURLKey)
                    ?? AppSettings.defaultServerURL)
        let token = KeychainStore.token() ?? ""
        return backendStatus(serverURL: base, token: token)
    }

    static func backendStatus(serverURL: String, token: String) -> BackendStatus {
        let base = normalizedServerURL(serverURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .missingServer }
        guard !token.isEmpty else { return .missingToken }
        guard let comps = URLComponents(string: base),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host,
              !host.isEmpty else {
            return .invalidURL
        }
        guard scheme == "https" || host == "localhost" || host == "127.0.0.1" else {
            return .insecureURL
        }
        return .ready
    }

    private static func credentials() -> (base: String, token: String)? {
        let base = (UserDefaults.standard.string(forKey: AppSettings.serverURLKey)
                    ?? AppSettings.defaultServerURL)
        let normalizedBase = normalizedServerURL(base)
        let token = (KeychainStore.token() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard backendStatus(serverURL: normalizedBase, token: token).isReady else { return nil }
        return (normalizedBase, token)
    }

    static func uploadForMeetingNotes(data: Data,
                                      filename: String,
                                      contentType: String,
                                      durationMs: Int64 = 0,
                                      onProgress: ((JobProgress) -> Void)? = nil) async throws -> MeetingNotesResult {
        switch backendStatus() {
        case .ready:
            break
        case .missingServer, .missingToken:
            throw SendError.notConfigured
        case .invalidURL:
            throw SendError.invalidURL
        case .insecureURL:
            throw SendError.insecureURL
        }
        guard let (base, token) = credentials() else {
            throw SendError.notConfigured
        }
        return try await uploadForMeetingNotesJob(data: data,
                                                  filename: filename,
                                                  contentType: contentType,
                                                  base: base,
                                                  token: token,
                                                  expectedDurationMs: durationMs,
                                                  onProgress: onProgress)
    }

    static func uploadForMeetingNotes(fileURL: URL,
                                      filename: String,
                                      contentType: String,
                                      durationMs: Int64 = 0,
                                      onProgress: ((JobProgress) -> Void)? = nil) async throws -> MeetingNotesResult {
        switch backendStatus() {
        case .ready:
            break
        case .missingServer, .missingToken:
            throw SendError.notConfigured
        case .invalidURL:
            throw SendError.invalidURL
        case .insecureURL:
            throw SendError.insecureURL
        }
        guard let (base, token) = credentials() else {
            throw SendError.notConfigured
        }
        return try await uploadForMeetingNotesJob(fileURL: fileURL,
                                                  filename: filename,
                                                  contentType: contentType,
                                                  base: base,
                                                  token: token,
                                                  expectedDurationMs: durationMs,
                                                  onProgress: onProgress)
    }

    private static func uploadForMeetingNotesJob(data: Data,
                                                 filename: String,
                                                 contentType: String,
                                                 base: String,
                                                 token: String,
                                                 expectedDurationMs: Int64,
                                                 onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        do {
            return try await uploadForMeetingNotesResumable(
                data: data,
                filename: filename,
                contentType: contentType,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        } catch is ResumableUploadUnavailable {
            return try await uploadForMeetingNotesLegacy(
                data: data,
                filename: filename,
                contentType: contentType,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        }
    }

    private static func uploadForMeetingNotesLegacy(data: Data,
                                                     filename: String,
                                                     contentType: String,
                                                     base: String,
                                                     token: String,
                                                     expectedDurationMs: Int64,
                                                     onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        var request = try uploadRequest(filename: filename,
                                        contentType: contentType,
                                        base: base,
                                        token: token)
        request.httpBody = data
        onProgress?(JobProgress(jobId: "", status: "uploading", stage: "uploading"))
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performUploadWithTimeout {
                try await URLSession.shared.data(for: request)
            }
        } catch {
            throw uploadTransportError(error)
        }
        return try await acceptedMeetingNotesResult(responseData: responseData,
                                                   response: response,
                                                   base: base,
                                                   token: token,
                                                   expectedDurationMs: expectedDurationMs,
                                                   onProgress: onProgress)
    }

    private static func uploadForMeetingNotesJob(fileURL: URL,
                                                 filename: String,
                                                 contentType: String,
                                                 base: String,
                                                 token: String,
                                                 expectedDurationMs: Int64,
                                                 onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        do {
            return try await uploadForMeetingNotesResumable(
                fileURL: fileURL,
                filename: filename,
                contentType: contentType,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        } catch is ResumableUploadUnavailable {
            return try await uploadForMeetingNotesLegacy(
                fileURL: fileURL,
                filename: filename,
                contentType: contentType,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        }
    }

    private static func uploadForMeetingNotesLegacy(fileURL: URL,
                                                     filename: String,
                                                     contentType: String,
                                                     base: String,
                                                     token: String,
                                                     expectedDurationMs: Int64,
                                                     onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        let request = try uploadRequest(filename: filename,
                                        contentType: contentType,
                                        base: base,
                                        token: token)
        onProgress?(JobProgress(jobId: "", status: "uploading", stage: "uploading"))
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await performUploadWithTimeout {
                try await URLSession.shared.upload(for: request, fromFile: fileURL)
            }
        } catch {
            throw uploadTransportError(error)
        }
        return try await acceptedMeetingNotesResult(responseData: responseData,
                                                   response: response,
                                                   base: base,
                                                   token: token,
                                                   expectedDurationMs: expectedDurationMs,
                                                   onProgress: onProgress)
    }

    private static func uploadForMeetingNotesResumable(data: Data,
                                                       filename: String,
                                                       contentType: String,
                                                       base: String,
                                                       token: String,
                                                       expectedDurationMs: Int64,
                                                       onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        let session = try await beginResumableUpload(
            filename: filename,
            contentType: contentType,
            sizeBytes: Int64(data.count),
            sha256: sha256Hex(data),
            base: base,
            token: token
        )
        if !session.completedJobId.isEmpty {
            return try await completeResumableUpload(
                session,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        }
        let uploaded = Set(session.uploadedChunks)
        let chunkCount = (data.count + session.chunkBytes - 1) / session.chunkBytes
        onProgress?(JobProgress(jobId: "", status: "uploading", stage: "uploading"))
        for chunkIndex in 0..<chunkCount where !uploaded.contains(chunkIndex) {
            let start = chunkIndex * session.chunkBytes
            let end = min(data.count, start + session.chunkBytes)
            try await uploadResumableChunk(
                data.subdata(in: start..<end),
                session: session,
                chunkIndex: chunkIndex,
                base: base,
                token: token
            )
        }
        return try await completeResumableUpload(
            session,
            base: base,
            token: token,
            expectedDurationMs: expectedDurationMs,
            onProgress: onProgress
        )
    }

    private static func uploadForMeetingNotesResumable(fileURL: URL,
                                                       filename: String,
                                                       contentType: String,
                                                       base: String,
                                                       token: String,
                                                       expectedDurationMs: Int64,
                                                       onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        let (sizeBytes, digest) = try fileSizeAndSHA256(fileURL)
        let session = try await beginResumableUpload(
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: digest,
            base: base,
            token: token
        )
        if !session.completedJobId.isEmpty {
            return try await completeResumableUpload(
                session,
                base: base,
                token: token,
                expectedDurationMs: expectedDurationMs,
                onProgress: onProgress
            )
        }

        let uploaded = Set(session.uploadedChunks)
        let chunkCount = (Int(sizeBytes) + session.chunkBytes - 1) / session.chunkBytes
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        onProgress?(JobProgress(jobId: "", status: "uploading", stage: "uploading"))
        for chunkIndex in 0..<chunkCount where !uploaded.contains(chunkIndex) {
            try handle.seek(toOffset: UInt64(chunkIndex * session.chunkBytes))
            let expected = min(session.chunkBytes, Int(sizeBytes) - chunkIndex * session.chunkBytes)
            guard let chunk = try handle.read(upToCount: expected), chunk.count == expected else {
                throw SendError.network("读取本地录音失败，录音已保留")
            }
            try await uploadResumableChunk(
                chunk,
                session: session,
                chunkIndex: chunkIndex,
                base: base,
                token: token
            )
        }
        return try await completeResumableUpload(
            session,
            base: base,
            token: token,
            expectedDurationMs: expectedDurationMs,
            onProgress: onProgress
        )
    }

    private static func beginResumableUpload(filename: String,
                                             contentType: String,
                                             sizeBytes: Int64,
                                             sha256: String,
                                             base: String,
                                             token: String) async throws -> ResumableUploadSession {
        guard let url = URL(string: base + "/internal/task/audio/uploads") else {
            throw SendError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ResumableUploadInitRequest(
            mode: "meeting_notes",
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            sha256: sha256
        ))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw uploadTransportError(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 || code == 405 {
            throw ResumableUploadUnavailable()
        }
        guard code == 200 else { throw SendError.http(code) }
        let session = try JSONDecoder().decode(ResumableUploadSession.self, from: data)
        guard session.chunkBytes > 0 else {
            throw SendError.network("服务器返回的分块大小无效，录音已保留")
        }
        return session
    }

    private static func uploadResumableChunk(_ chunk: Data,
                                             session: ResumableUploadSession,
                                             chunkIndex: Int,
                                             base: String,
                                             token: String) async throws {
        guard let url = URL(string: base + "/internal/task/audio/uploads/\(session.uploadId)/chunks/\(chunkIndex)") else {
            throw SendError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(sha256Hex(chunk), forHTTPHeaderField: "X-Chunk-SHA256")
        request.httpBody = chunk
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw uploadTransportError(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SendError.http(code) }
    }

    private static func completeResumableUpload(_ session: ResumableUploadSession,
                                                base: String,
                                                token: String,
                                                expectedDurationMs: Int64,
                                                onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        guard let url = URL(string: base + "/internal/task/audio/uploads/\(session.uploadId)/complete") else {
            throw SendError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw uploadTransportError(error)
        }
        return try await acceptedMeetingNotesResult(
            responseData: responseData,
            response: response,
            base: base,
            token: token,
            expectedDurationMs: expectedDurationMs,
            onProgress: onProgress
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSizeAndSHA256(_ fileURL: URL) throws -> (Int64, String) {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw SendError.network("读取本地录音大小失败，录音已保留")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (number.int64Value, digest)
    }

    private static func uploadRequest(filename: String,
                                      contentType: String,
                                      base: String,
                                      token: String) throws -> URLRequest {
        guard var comps = URLComponents(string: base + "/internal/task/audio/jobs") else {
            throw SendError.invalidURL
        }
        comps.queryItems = [
            URLQueryItem(name: "mode", value: "meeting_notes"),
            URLQueryItem(name: "filename", value: filename)
        ]
        guard let url = comps.url else { throw SendError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func performUploadWithTimeout(
        _ operation: @escaping () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: uploadAcceptTimeoutNanoseconds)
                throw SendError.network("上传超时，录音已保留，可重试")
            }

            guard let result = try await group.next() else {
                throw SendError.network("上传超时，录音已保留，可重试")
            }
            group.cancelAll()
            return result
        }
    }

    private static func uploadTransportError(_ error: Error) -> Error {
        if let sendError = error as? SendError {
            return sendError
        }
        guard let urlError = error as? URLError else {
            return error
        }
        switch urlError.code {
        case .timedOut:
            return SendError.network("上传超时，录音已保留，可重试")
        case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost:
            return SendError.network("上传中断，录音已保留，可重试")
        default:
            return SendError.network(urlError.localizedDescription)
        }
    }

    private static func acceptedMeetingNotesResult(responseData: Data,
                                                   response: URLResponse,
                                                   base: String,
                                                   token: String,
                                                   expectedDurationMs: Int64,
                                                   onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SendError.http(code) }
        let accepted = try JSONDecoder().decode(JobAcceptedResponse.self, from: responseData)
        onProgress?(JobProgress(jobId: accepted.jobId, status: accepted.status, stage: "queued"))
        return try await pollMeetingNotesJob(jobId: accepted.jobId,
                                             base: base,
                                             token: token,
                                             expectedDurationMs: expectedDurationMs,
                                             onProgress: onProgress)
    }

    private static func pollMeetingNotesJob(jobId: String,
                                            base: String,
                                            token: String,
                                            expectedDurationMs: Int64,
                                            onProgress: ((JobProgress) -> Void)?) async throws -> MeetingNotesResult {
        guard let url = URL(string: base + "/internal/task/audio/jobs/\(jobId)") else {
            throw SendError.invalidURL
        }
        let deadline = Date().addingTimeInterval(45 * 60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw SendError.http(code) }
            let status = try JSONDecoder().decode(JobStatusResponse.self, from: responseData)
            onProgress?(JobProgress(jobId: jobId,
                                    status: status.status,
                                    stage: status.stage ?? status.status))
            switch status.status {
            case "succeeded":
                return try meetingNotesResult(from: status,
                                              jobId: jobId,
                                              expectedDurationMs: expectedDurationMs)
            case "failed":
                if hasTranscriptEvidence(status) {
                    return try meetingNotesResult(from: status,
                                                  jobId: jobId,
                                                  expectedDurationMs: expectedDurationMs)
                }
                if isEmptyTranscriptMessage(status.error) {
                    throw SendError.network("本次重试未识别出文字，录音已保留，可重试")
                }
                throw SendError.network(status.error ?? "长录音生成失败")
            default:
                continue
            }
        }
        throw SendError.network("长录音生成超时，请稍后重试")
    }

    private static func meetingNotesResult(from status: JobStatusResponse,
                                           jobId: String,
                                           expectedDurationMs: Int64) throws -> MeetingNotesResult {
        let segments = (status.segments ?? []).map {
            TranscriptSegment(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
        }.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let response = UploadResponse(text: status.text,
                                      transcript: status.transcript,
                                      notes: status.notes,
                                      segments: status.segments,
                                      timingSource: status.timingSource,
                                      audioDurationSeconds: status.audioDurationSeconds,
                                      timelineCoverage: status.timelineCoverage,
                                      segmentTextCoverage: status.segmentTextCoverage)
        let transcript = completeTranscript(response: response, segments: segments)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SendError.network("本次重试未识别出文字，录音已保留，可重试")
        }
        guard !segments.isEmpty else {
            throw SendError.network("服务器没有返回逐句时间轴")
        }
        try validateServerAudioDuration(status.audioDurationSeconds,
                                        expectedDurationMs: expectedDurationMs)
        try validateTranscriptTimelineCoverage(status.timelineCoverage,
                                               segmentTextCoverage: status.segmentTextCoverage)
        return MeetingNotesResult(transcript: transcript,
                                  notes: status.notes ?? "",
                                  segments: segments,
                                  jobId: jobId)
    }

    private static func hasTranscriptEvidence(_ status: JobStatusResponse) -> Bool {
        let transcript = (status.transcript ?? status.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            return true
        }
        return (status.segments ?? []).contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func isEmptyTranscriptMessage(_ value: String?) -> Bool {
        let text = (value ?? "").lowercased()
        return text.contains("empty transcript")
            || text.contains("asr returned empty")
            || text.contains("没有返回完整转写")
            || text.contains("未识别出文字")
    }

#if DEBUG
    static func debugMeetingNotesResultForTesting(jobStatusJSON data: Data,
                                                  jobId: String = "debug-job",
                                                  expectedDurationMs: Int64 = 0) throws -> MeetingNotesResult {
        let status = try JSONDecoder().decode(JobStatusResponse.self, from: data)
        switch status.status {
        case "succeeded":
            return try meetingNotesResult(from: status,
                                          jobId: jobId,
                                          expectedDurationMs: expectedDurationMs)
        case "failed":
            if hasTranscriptEvidence(status) {
                return try meetingNotesResult(from: status,
                                              jobId: jobId,
                                              expectedDurationMs: expectedDurationMs)
            }
            if isEmptyTranscriptMessage(status.error) {
                throw SendError.network("本次重试未识别出文字，录音已保留，可重试")
            }
            throw SendError.network(status.error ?? "长录音生成失败")
        default:
            throw SendError.network("长录音仍在处理中")
        }
    }
#endif

    static func normalizedServerURL(_ value: String) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    private static func completeTranscript(response: UploadResponse, segments: [TranscriptSegment]) -> String {
        let transcript = (response.transcript ?? response.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            return transcript
        }
        return segments
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
    }

    private static func validateServerAudioDuration(_ audioDurationSeconds: Double?,
                                                    expectedDurationMs: Int64) throws {
        guard expectedDurationMs > 0 else { return }
        let expectedSeconds = Double(expectedDurationMs) / 1000.0
        guard expectedSeconds >= 8 * 60 else { return }
        guard let audioDurationSeconds, audioDurationSeconds > 0 else {
            throw SendError.network("服务器没有返回录音时长，请重新生成")
        }
        let allowedDrift = max(30.0, expectedSeconds * 0.05)
        guard abs(audioDurationSeconds - expectedSeconds) <= allowedDrift else {
            throw SendError.network("服务器处理的录音时长和本地录音不一致，请重新上传")
        }
    }

    private static func validateTranscriptTimelineCoverage(_ timelineCoverage: Double?,
                                                           segmentTextCoverage: Double?) throws {
        if let timelineCoverage, timelineCoverage < 0.85 {
            throw SendError.network("服务器返回的逐句时间轴没有覆盖完整录音，请重新生成")
        }
        guard let segmentTextCoverage else { return }
        guard segmentTextCoverage >= 0.85 else {
            throw SendError.network("服务器返回的逐句时间轴不完整，请重新生成")
        }
    }
}

enum BackendConfigurationLink {
    struct Configuration {
        let serverURL: String
        fileprivate let token: String

        fileprivate init(serverURL: String, token: String) {
            self.serverURL = serverURL
            self.token = token
        }
    }

    enum PreviewResult {
        case ready(Configuration)
        case rejected(ApplyResult)
    }

    enum ApplyResult: Equatable {
        case applied(serverURL: String)
        case ignored
        case invalid(String)
        case keychainFailed

        var feedback: CopyFeedback? {
            switch self {
            case .applied:
                return CopyFeedback(text: "后端配置已保存", severity: .success)
            case .ignored:
                return nil
            case .invalid(let message):
                return CopyFeedback(text: message, severity: .warning)
            case .keychainFailed:
                return CopyFeedback(text: "API Token 保存失败，请解锁设备后重试", severity: .warning)
            }
        }
    }

    static func make(serverURL: String, token: String) -> URL? {
        let server = MeetingNotesAPI.normalizedServerURL(serverURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MeetingNotesAPI.backendStatus(serverURL: server, token: token).isReady else { return nil }
        var comps = URLComponents()
        comps.scheme = "wanji"
        comps.host = "configure"
        comps.queryItems = [
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "token", value: token)
        ]
        return comps.url
    }

    static func apply(_ url: URL) -> ApplyResult {
        switch preview(url) {
        case .ready(let configuration): return apply(configuration)
        case .rejected(let result): return result
        }
    }

    static func preview(_ url: URL) -> PreviewResult {
        guard url.scheme?.lowercased() == "wanji" else { return .rejected(.ignored) }
        let host = url.host?.lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard host == "configure" || path == "configure" else {
            return .rejected(.invalid("配置链接不可用"))
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .rejected(.invalid("配置链接格式不正确"))
        }
        let items = comps.queryItems ?? []
        let server = value(named: "server", in: items)
            ?? value(named: "url", in: items)
            ?? value(named: "base", in: items)
            ?? ""
        let token = value(named: "token", in: items)
            ?? value(named: "api_token", in: items)
            ?? ""
        let normalizedServer = MeetingNotesAPI.normalizedServerURL(server)
        switch MeetingNotesAPI.backendStatus(serverURL: normalizedServer, token: token) {
        case .ready:
            break
        case .missingServer:
            return .rejected(.invalid("配置链接缺少服务器地址"))
        case .missingToken:
            return .rejected(.invalid("配置链接缺少 API Token"))
        case .invalidURL:
            return .rejected(.invalid("配置链接里的服务器地址格式不正确"))
        case .insecureURL:
            return .rejected(.invalid("配置链接里的服务器地址需要使用 HTTPS"))
        }
        return .ready(Configuration(serverURL: normalizedServer,
                                    token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func apply(_ configuration: Configuration) -> ApplyResult {
        guard KeychainStore.setToken(configuration.token) else {
            return .keychainFailed
        }
        UserDefaults.standard.set(configuration.serverURL, forKey: AppSettings.serverURLKey)
        return .applied(serverURL: configuration.serverURL)
    }

    static func apply(_ text: String) -> ApplyResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .ignored }
        guard let url = URL(string: value) else {
            return value.lowercased().hasPrefix("wanji://")
                ? .invalid("配置链接格式不正确")
                : .ignored
        }
        return apply(url)
    }

    private static func value(named name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name.lowercased() == name }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
