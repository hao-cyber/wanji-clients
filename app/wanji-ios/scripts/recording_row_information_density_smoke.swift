import Foundation

@main
struct RecordingRowInformationDensitySmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        let rowStart = content.range(of: "struct RecordingRow: View")!.lowerBound
        let rowEnd = content.range(of: "struct RecordingRecoveryHint: View")!.lowerBound
        let row = content[rowStart..<rowEnd]

        precondition(row.contains("private var compactStatusText"),
                     "Recording rows should condense backend status into a compact display string")
        precondition(row.contains("let titleText: String") &&
                     row.contains("Text(titleText)") &&
                     row.contains(#"item.source == "watch" ? nil : "导入""#) &&
                     !row.contains("item.formattedSize") &&
                     !row.contains("item.sourceText"),
                     "Rows should show grouped time and duration, with source metadata only for imports")
        precondition(row.contains("private static let missingNotesText"),
                     "Repeated missing-notes sentinel copy should be centralized")
        precondition(!row.contains("parts.append(\"需要重试\")") &&
                     !row.contains("parts.append(\"排队中\")") &&
                     !row.contains("parts.append(\"生成中\")") &&
                     !row.contains("parts.append(item.originalName)"),
                     "Recording metadata should not repeat state or expose raw debug filenames")
        precondition(row.contains("transcriptComplete || notesComplete || item.noteText == Self.missingNotesText"),
                     "Transcript and notes entry buttons should appear only when there is content to inspect")
        precondition(row.contains("private var shouldShowGenerateButton") &&
                     row.contains("backendReady && item.audioRetained") &&
                     !row.contains(#"return "去设置""#),
                     "Rows without generation capability should not repeat the global backend setup action")
        precondition(row.contains("if item.state == .local && !backendReady") &&
                     row.contains("return false") &&
                     !row.contains("录音已保存在本机；开启转写后可生成文字。"),
                     "Local-only rows should not repeat unavailable processing or reassurance copy")
        precondition(!row.contains(#"Image(systemName: "applewatch")"#) &&
                     row.contains(#"Label(playing ? "停止" : "播放""#) &&
                     !row.contains(#".background(Color.panelMuted, in: Circle())"#),
                     "Recording rows should avoid duplicate source icons and use a lightweight text playback action")
        precondition(!row.contains("Menu {") &&
                     row.contains("private var swipeGesture: some Gesture") &&
                     row.contains(#"Text("查看内容")"#) &&
                     row.contains(#"Image(systemName: "chevron.right")"#),
                     "Playback and content should be clear first-level actions while deletion uses a labeled swipe action")
        precondition(row.contains(#"Label(playing ? "停止" : "播放""#) &&
                     row.contains("frame(maxWidth: hasSecondaryAction ? .infinity : nil, minHeight: 44)"),
                     "Playback and content actions should share a balanced text-action treatment")
        precondition(row.contains(#"Button("只删除原音频", role: .destructive, action: onDeleteAudio)"#) &&
                     row.contains("Button(deleteDialogActionTitle, role: .destructive, action: onDelete)"),
                     "One delete entry should safely distinguish audio cleanup from deleting the whole record")
        precondition(!content.contains("let preview: String") &&
                     !content.contains("Text(String(preview.prefix"),
                     "Recording content entry buttons should not duplicate transcript or note previews on the list surface")
        precondition(row.contains("RecordingStepSummary(title: \"转写\"") &&
                     !row.contains("RecordingStepSummary(title: \"完整转写\""),
                     "List step labels should use compact terms; full terminology belongs in detail views")

        print("recording_row_information_density_smoke passed")
    }
}
