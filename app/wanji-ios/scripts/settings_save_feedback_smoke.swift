import Foundation

@main
struct SettingsSaveFeedbackSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("@State private var backendSaving = false"),
                     "backend config save should keep local in-flight state")
        precondition(content.contains("if backendSaving"),
                     "backend save button should show immediate progress feedback")
        precondition(content.contains("@State private var manualConfigExpanded = false") &&
                     content.contains("DisclosureGroup(isExpanded: $manualConfigExpanded)"),
                     "Technical server fields should stay behind an explicit manual configuration disclosure")
        precondition(content.contains(#"Label("从剪贴板导入配置", systemImage: "doc.on.clipboard")"#) &&
                     content.contains(#"Text("文字整理")"#) &&
                     !content.contains(#"Text("连接设置")"#) &&
                     !content.contains(#"Text("录音与隐私")"#),
                     "Settings should consolidate backend controls without redundant read-only sections")
        precondition(content.contains("正在保存后端配置"),
                     "backend save loading state should say what is happening, not show a lone spinner")
        precondition(content.contains(".disabled(!backendCanSave || settingsBusy)"),
                     "backend save should prevent duplicate taps while settings are busy")
        precondition(content.contains(".disabled(backendConfigurationURL == nil || settingsBusy)"),
                     "configuration link copy should be disabled while settings are busy or invalid")
        precondition(content.contains("showBackendLinkFeedback(CopyFeedback(text: \"剪贴板没有配置链接\""),
                     "manual pasteboard import should give recoverable empty-clipboard feedback")
        precondition(content.contains(".interactiveDismissDisabled(settingsHasUnsavedChanges || settingsBusy)"),
                     "settings should not dismiss while a save is in flight")
        precondition(content.contains("try? await Task.sleep(nanoseconds: 120_000_000)"),
                     "settings save should yield long enough for visible feedback before synchronous persistence")
        precondition(content.contains(#"Text("数据管理")"#) &&
                     content.contains(#"Label("导入音频", systemImage: "square.and.arrow.down")"#) &&
                     content.contains(#"LabeledContent("本机录音""#) &&
                     content.contains(#"LabeledContent("占用空间""#) &&
                     content.contains(#"Label("清空全部录音", systemImage: "trash")"#) &&
                     content.contains(#"Label("清理已完成原音频", systemImage: "waveform.slash")"#),
                     "Import, storage metrics, and bulk cleanup should share one deliberate data-management section")

        print("settings_save_feedback_smoke passed")
    }
}
