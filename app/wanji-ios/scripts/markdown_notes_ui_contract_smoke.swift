import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root
    .appendingPathComponent("app/wanji-ios/Wanji/ContentView.swift")
let text = try String(contentsOf: source, encoding: .utf8)

precondition(
    text.contains("MarkdownNoteSection(markdown: meaningfulNoteText)"),
    "notes page must render server markdown through a markdown-aware section"
)
precondition(
    text.contains("if shouldShowNoteContext {") &&
        text.contains("NoteContextBanner(context: noteContext)") &&
        text.contains("meaningfulNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty") &&
        text.contains("struct NoteContextBanner: View"),
    "notes page should explain exceptional empty states without repeating success context"
)
precondition(
    text.contains("enum RecordingDetailKind") &&
        text.contains("case notes") &&
        text.contains("RecordingDetailView(item: item,") &&
        text.contains("Picker(\"内容类型\"") &&
        text.contains(".pickerStyle(.segmented)"),
    "notes and transcript should share one clear segmented detail destination"
)
precondition(
    text.contains("onOpenNotes") &&
        text.contains("Button(action: openGeneratedContent)") &&
        text.contains("Text(\"查看内容\")") &&
        text.contains("Image(systemName: \"chevron.right\")"),
    "recording rows should expose one unified generated-content entry"
)
precondition(
    text.contains("Text(\"转写\").tag(RecordingDetailKind.transcript)") &&
        text.contains("Text(\"纪要\").tag(RecordingDetailKind.notes)"),
    "notes should keep an explicit evidence route back to the full transcript"
)
precondition(
    !text.contains("基于完整转写生成") &&
        text.contains("纪要未返回") &&
        text.contains("等待完整转写") &&
        text.contains("纪要生成失败"),
    "notes detail must stay quiet on success and distinguish missing, waiting, and failed states"
)
precondition(
    text.contains("struct MarkdownNoteSection: View") &&
        !text[text.range(of: "struct MarkdownNoteSection: View")!.lowerBound..<text.range(of: "private struct MarkdownBlock:")!.lowerBound]
            .contains("Text(\"纪要\")"),
    "markdown notes renderer should be first-class UI without duplicating the selected tab title"
)
precondition(
    text.contains("case .heading") &&
        text.contains("case .bullet") &&
        text.contains("case .task") &&
        text.contains("case .numbered") &&
        text.contains("case .quote") &&
        text.contains("case .table") &&
        text.contains("case .code"),
    "markdown notes should support headings, lists, tasks, quotes, tables, and code blocks"
)
precondition(
    text.contains("AttributedString(markdown: text"),
    "markdown notes should preserve inline markdown such as bold and emphasis"
)
precondition(
    text.contains("parseTask(_ line: String)") &&
        text.contains("checkmark.circle.fill") &&
        text.contains("parseTable(startingAt index: Int, lines: [String])") &&
        text.contains("MarkdownTableRow"),
    "server markdown notes should adapt common action-item checklists and simple tables into native iOS views"
)
precondition(
    text.contains("static func previewText(from markdown: String) -> String") &&
        text.contains("case .table(let headers, let rows)"),
    "markdown previews should strip control syntax when a compact preview is needed"
)
precondition(
    text.contains("case .notes:") &&
        text.contains("return meaningfulNoteText") &&
        text.contains("kind.copyLabel") &&
        text.contains("kind.shareLabel"),
    "copy/share should keep the original markdown notes text"
)
precondition(
    text.contains("Text(regenerating ? \"正在重新生成\" : \"重新生成纪要\")") &&
        text.contains("confirmationDialog(\"重新生成这份纪要？\"") &&
        text.contains("失败时保留当前纪要和原音频") &&
        text.contains("Task { await store.generateNotes(for: item) }"),
    "completed notes with retained audio must expose a confirmed, recoverable regeneration path"
)

print("markdown_notes_ui_contract_smoke passed")
