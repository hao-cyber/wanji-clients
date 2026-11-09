import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root
    .appendingPathComponent("app/wanji-ios/Wanji/ContentView.swift")
let text = try String(contentsOf: source, encoding: .utf8)

precondition(
    text.contains("TranscriptDetailSection(text: displayTranscriptText"),
    "full transcript page must render transcript text through TranscriptDetailSection"
)
precondition(
    text.contains("enum RecordingDetailKind") &&
        text.contains("case transcript") &&
        text.contains("Picker(\"内容类型\"") &&
        text.contains(".pickerStyle(.segmented)"),
    "generated content should use one detail destination with an explicit transcript/notes switch"
)
precondition(
    text.contains("onOpenTranscript") &&
        text.contains("Button(action: openGeneratedContent)") &&
        text.contains("Text(\"查看内容\")") &&
        text.contains("Image(systemName: \"chevron.right\")"),
    "recording rows should expose one unified generated-content entry"
)
precondition(
    text.contains("segments: item.transcriptSegments"),
    "full transcript page must receive sentence-level backend segments"
)
precondition(
    text.contains("onPlaySegment(segment.startSeconds)"),
    "sentence row taps must seek playback to the sentence start time"
)
precondition(
    text.contains("ForEach(visibleSegments) { segment in") && text.contains("Button {"),
    "sentence-level jumps should be inline transcript row buttons"
)
precondition(
    text.contains("if canPlayAudio {") &&
        text.contains("segmentRow(segment, active: active)") &&
        !text.contains(".disabled(!canPlayAudio)"),
    "read-only transcript rows should stay readable instead of being dimmed by disabled Button styling"
)
precondition(
    text.contains("Text(segment.text)") && text.contains("Text(segment.timeText)"),
    "each transcript sentence row must show both timestamp and text"
)
precondition(
    text.contains("没有逐句时间轴，不能跳到对应录音位置。"),
    "full transcript fallback must explain when sentence-level jump data is missing"
)
precondition(
    text.contains("return item.transcriptSegments") && text.contains("joined(separator: \" \")"),
    "detail view must still show transcript text when only segments are available"
)
precondition(
    text.contains("if shouldShowTranscriptContext {") &&
        text.contains("NoteContextBanner(context: transcriptContext)") &&
        text.contains("可逐句核对") &&
        text.contains("只能查看文字") &&
        text.contains("完整转写生成中"),
    "transcript page should explain only processing, failures, missing audio, or missing timeline states in-place"
)
let transcriptSectionStart = text.range(of: "struct TranscriptDetailSection: View")!.lowerBound
let transcriptSectionEnd = text.range(of: "struct DetailPlaybackHeader: View")!.lowerBound
precondition(
    !text[transcriptSectionStart..<transcriptSectionEnd].contains("Text(\"完整转写\")"),
    "transcript content should not duplicate the selected tab title"
)
precondition(
    text.contains("Text(\"转写\").tag(RecordingDetailKind.transcript)") &&
        text.contains("Text(\"纪要\").tag(RecordingDetailKind.notes)"),
    "transcript and notes should remain explicitly reachable in the shared detail view"
)

print("transcript_sentence_jump_ui_contract_smoke passed")
