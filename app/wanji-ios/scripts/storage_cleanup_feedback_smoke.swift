import Foundation

@main
struct StorageCleanupFeedbackSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("@State private var storageAction: StorageAction?"),
                     "storage cleanup should keep local in-flight state")
        precondition(content.contains("storageAction == .clearAll"),
                     "clear-all buttons should show their own progress state")
        precondition(content.contains("storageAction == .clearCompleted"),
                     "completed-audio cleanup should show its own progress state")
        precondition(content.contains(".disabled(store.hasActiveGeneration || storageAction != nil)"),
                     "storage cleanup controls should prevent duplicate destructive taps")
        precondition(content.contains("正在清理本机录音"),
                     "privacy panel should explain the cleanup in progress")
        precondition(content.contains("try? await Task.sleep(nanoseconds: 120_000_000)"),
                     "cleanup should yield long enough for visible feedback before synchronous deletion")

        print("storage_cleanup_feedback_smoke passed")
    }
}
