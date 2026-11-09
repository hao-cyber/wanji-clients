import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let apiSource = root
    .appendingPathComponent("app/wanji-ios/Wanji/MeetingNotesAPI.swift")
let storeSource = root
    .appendingPathComponent("app/wanji-ios/Wanji/RecordingStore.swift")
let api = try String(contentsOf: apiSource, encoding: .utf8)
let store = try String(contentsOf: storeSource, encoding: .utf8)

precondition(
    api.contains("case \"failed\":") && api.contains("if hasTranscriptEvidence(status)"),
    "failed backend jobs with retained transcript evidence must not be treated as pure failures"
)
precondition(
    api.contains("return try meetingNotesResult(from: status"),
    "failed jobs with transcript evidence must reuse the same transcript/segment validation path as succeeded jobs"
)
precondition(
    api.contains("private static func hasTranscriptEvidence"),
    "MeetingNotesAPI needs an explicit transcript-evidence gate for failed jobs"
)
precondition(
    api.contains("private static func meetingNotesResult"),
    "MeetingNotesAPI should avoid diverging succeeded and failed transcript extraction logic"
)
precondition(
    store.contains("items[current].noteText = result.notes.isEmpty") &&
    store.contains("\"服务器已完成转写，但没有返回纪要。\""),
    "RecordingStore must persist transcript-only results with a clear notes-missing placeholder"
)
precondition(
    store.contains("items[current].transcriptText = result.transcript") &&
    store.contains("items[current].transcriptSegments = result.segments"),
    "RecordingStore must persist transcript and sentence segments even when notes are empty"
)

print("transcript_preserved_when_notes_fail_smoke passed")
