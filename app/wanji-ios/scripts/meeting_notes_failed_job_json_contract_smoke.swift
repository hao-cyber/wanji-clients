import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("app/wanji-ios/Wanji/MeetingNotesAPI.swift")
let temp = FileManager.default.temporaryDirectory
    .appendingPathComponent("wanji-meeting-notes-json-contract-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }

let stubs = temp.appendingPathComponent("Stubs.swift")
try """
import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable {
    let id = UUID()
    let startMs: Int64
    let endMs: Int64
    let text: String
}

enum AppSettings {
    static let serverURLKey = "serverURL"
    static let defaultServerURL = ""
}

enum KeychainStore {
    static func token() -> String? { nil }
    static func setToken(_ token: String) -> Bool { true }
}
""".write(to: stubs, atomically: true, encoding: .utf8)

let main = temp.appendingPathComponent("main.swift")
try #"""
import Foundation

func data(_ json: String) -> Data {
    json.data(using: .utf8)!
}

let failedWithTranscript = data("""
{
  "status": "failed",
  "error": "meeting notes quality gate failed",
  "stage": "failed",
  "text": "",
  "transcript": "第一句讨论预算。第二句确认下周三报价。",
  "notes": "",
  "segments": [
    {"start_ms": 0, "end_ms": 900000, "text": "第一句讨论预算。"},
    {"start_ms": 900000, "end_ms": 1800000, "text": "第二句确认下周三报价。"}
  ],
  "timing_source": "provider_chunks",
  "audio_duration_seconds": 1800.0,
  "timeline_coverage": 1.0,
  "segment_text_coverage": 1.0
}
""")

let result = try MeetingNotesAPI.debugMeetingNotesResultForTesting(
    jobStatusJSON: failedWithTranscript,
    jobId: "job-failed-transcript",
    expectedDurationMs: 1_800_000
)
precondition(result.jobId == "job-failed-transcript")
precondition(result.transcript == "第一句讨论预算。第二句确认下周三报价。")
precondition(result.notes.isEmpty)
precondition(result.segments.count == 2)
precondition(result.segments[1].startMs == 900000)

let failedWithoutTranscript = data("""
{
  "status": "failed",
  "error": "ASR transcript quality gate failed",
  "stage": "failed",
  "text": "",
  "transcript": "",
  "notes": "",
  "segments": []
}
""")

do {
    _ = try MeetingNotesAPI.debugMeetingNotesResultForTesting(jobStatusJSON: failedWithoutTranscript)
    preconditionFailure("failed job without transcript evidence must throw")
} catch MeetingNotesAPI.SendError.network(let message) {
    precondition(message.contains("ASR transcript quality gate failed"))
}

let lowCoverage = data("""
{
  "status": "failed",
  "error": "meeting notes failed after ASR",
  "stage": "failed",
  "text": "",
  "transcript": "第一句讨论预算。第二句确认下周三报价。",
  "notes": "",
  "segments": [
    {"start_ms": 0, "end_ms": 900000, "text": "第一句讨论预算。"}
  ],
  "timing_source": "provider_chunks",
  "audio_duration_seconds": 1800.0,
  "timeline_coverage": 1.0,
  "segment_text_coverage": 0.5
}
""")

do {
    _ = try MeetingNotesAPI.debugMeetingNotesResultForTesting(
        jobStatusJSON: lowCoverage,
        jobId: "job-low-coverage",
        expectedDurationMs: 1_800_000
    )
    preconditionFailure("failed job with partial timed transcript must throw")
} catch MeetingNotesAPI.SendError.network(let message) {
    precondition(message.contains("逐句时间轴不完整"))
}

if CommandLine.arguments.count > 1 {
    let capturedURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let captured = try Data(contentsOf: capturedURL)
    let expectedDurationMs: Int64? = CommandLine.arguments.count > 2
        ? Int64(CommandLine.arguments[2])
        : nil
    let capturedResult = try MeetingNotesAPI.debugMeetingNotesResultForTesting(
        jobStatusJSON: captured,
        jobId: "captured-production-job",
        expectedDurationMs: expectedDurationMs ?? 0
    )
    precondition(!capturedResult.transcript.isEmpty)
    precondition(!capturedResult.notes.isEmpty)
    precondition(!capturedResult.segments.isEmpty)
}

print("meeting_notes_failed_job_json_contract_smoke passed")
"""#.write(to: main, atomically: true, encoding: .utf8)

let binary = temp.appendingPathComponent("meeting-notes-json-contract")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
process.arguments = [
    "-D", "DEBUG",
    stubs.path,
    source.path,
    main.path,
    "-o", binary.path,
]
let compileErr = Pipe()
process.standardError = compileErr
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    let err = String(data: compileErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    fatalError("swiftc failed: \(err)")
}

let run = Process()
run.executableURL = binary
run.arguments = Array(CommandLine.arguments.dropFirst())
let out = Pipe()
let err = Pipe()
run.standardOutput = out
run.standardError = err
try run.run()
run.waitUntilExit()
let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
if run.terminationStatus != 0 {
    fatalError("contract binary failed: \(stderr)")
}
print(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
