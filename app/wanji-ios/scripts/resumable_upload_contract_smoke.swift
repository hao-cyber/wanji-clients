import Foundation

@main
struct ResumableUploadContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Wanji/MeetingNotesAPI.swift"),
            encoding: .utf8
        )

        precondition(source.contains("import CryptoKit"),
                     "resumable uploads must hash the retained recording")
        precondition(source.contains("/internal/task/audio/uploads"),
                     "iOS must initialize the resumable upload protocol")
        precondition(source.contains("X-Chunk-SHA256"),
                     "every upload chunk must carry an integrity digest")
        precondition(source.contains("Set(session.uploadedChunks)"),
                     "a retry must skip chunks already retained by the server")
        precondition(source.contains("catch is ResumableUploadUnavailable"),
                     "legacy fallback must be limited to an unavailable resumable endpoint")
        precondition(!source.contains("pollCompletedUploadSession"),
                     "a completed failed job must return through complete so the server can requeue it")
        precondition(source.contains("FileHandle(forReadingFrom: fileURL)"),
                     "large recordings must be hashed and chunked without loading the whole file")

        print("resumable_upload_contract_smoke passed")
    }
}
