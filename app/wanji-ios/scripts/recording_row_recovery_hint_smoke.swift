import Foundation

@main
struct RecordingRowRecoveryHintSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("struct RecordingRecoveryHint"),
                     "recording rows should have an inline recovery hint component")
        precondition(content.contains("if let recoveryText"),
                     "recording rows should render recovery guidance when audio is unavailable")
        precondition(content.contains("原音频不在手机上；请从手表重新上传，或导入原文件后再生成完整转写。"),
                     "missing-audio rows should explain the next recovery action")
        precondition(content.contains("原音频已清理；纪要可继续查看和分享，不能重新生成。"),
                     "completed notes with removed audio should explain what still works")
        precondition(content.contains("accessibilityLabel(\"录音恢复提示：\\(text)\")"),
                     "recovery hints should be available to assistive technologies")

        print("recording_row_recovery_hint_smoke passed")
    }
}
