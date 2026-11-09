import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root
    .appendingPathComponent("app/wanji-ios/Wanji/MeetingNotesAPI.swift")
let text = try String(contentsOf: source, encoding: .utf8)

precondition(
    text.contains("case segmentTextCoverage = \"segment_text_coverage\""),
    "MeetingNotesAPI must decode backend segment_text_coverage"
)
precondition(
    text.contains("case timelineCoverage = \"timeline_coverage\""),
    "MeetingNotesAPI must decode backend timeline_coverage"
)
precondition(
    text.contains("case audioDurationSeconds = \"audio_duration_seconds\""),
    "MeetingNotesAPI must decode backend audio_duration_seconds"
)
precondition(
    text.contains("try validateServerAudioDuration(status.audioDurationSeconds"),
    "polling success path must reject server results whose audio duration does not match the local recording"
)
precondition(
    text.contains("try validateTranscriptTimelineCoverage(status.timelineCoverage"),
    "polling success path must reject incomplete transcript timeline coverage"
)
precondition(
    text.contains("timelineCoverage < 0.85") && text.contains("segmentTextCoverage >= 0.85"),
    "iOS segment-text coverage guard should match the backend acceptance threshold"
)
precondition(
    text.contains("服务器返回的逐句时间轴不完整"),
    "low coverage should surface a recoverable user-facing error"
)
precondition(
    text.contains("服务器处理的录音时长和本地录音不一致"),
    "duration mismatch should surface a recoverable user-facing error"
)

print("transcript_timeline_coverage_contract_smoke passed")
