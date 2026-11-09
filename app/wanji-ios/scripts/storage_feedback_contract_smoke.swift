import Foundation

@main
struct StorageFeedbackContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        guard let feedbackPanel = content.range(of: "if let storageFeedback"),
              let errorPanel = content.range(of: "if let error = store.errorText"),
              let queueSection = content.range(of: "queueSection") else {
            preconditionFailure("home layout anchors changed")
        }
        precondition(feedbackPanel.lowerBound < errorPanel.lowerBound &&
                     feedbackPanel.lowerBound < queueSection.lowerBound,
                     "storage feedback should stay globally visible even after clear-all empties the list")
        precondition(content[feedbackPanel.lowerBound..<errorPanel.lowerBound]
                        .contains("CopyConfirmationRow(feedback: storageFeedback)"),
                     "global storage feedback should use the same accessible confirmation row")

        precondition(content.contains("private func deleteRecording(_ item: MeetingRecording)"),
                     "row delete should go through a feedback wrapper")
        precondition(content.contains("private func clearAllLocalRecordings()"),
                     "clear-all should go through a feedback wrapper")
        precondition(content.contains("showStorageWarning(store.errorText ??"),
                     "destructive failure paths should surface an inline warning")
        precondition(content.contains("已清空 \\(count) 条本机记录"),
                     "clear-all success should give explicit confirmation")

        print("storage_feedback_contract_smoke passed")
    }
}
