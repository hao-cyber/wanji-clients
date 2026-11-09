import Foundation

@main
struct SyncIdleTimerSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains(#".onChange(of: watchPullClient.syncing)"#) &&
                     content.contains("updateIdleTimer()"),
                     "Idle timer should react immediately when watch sync starts or stops")
        precondition(content.contains("UIApplication.shared.isIdleTimerDisabled = scenePhase == .active") &&
                     content.contains("watchPullClient.syncing || store.hasActiveGeneration"),
                     "The phone should stay awake only for foreground watch sync or active generation")
        precondition(content.contains("UIApplication.shared.isIdleTimerDisabled = false"),
                     "The app should restore the idle timer on disappear")

        print("sync_idle_timer_smoke passed")
    }
}
