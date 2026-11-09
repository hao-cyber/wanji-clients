import Foundation

@main
struct AutoPullLatencyContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)

        precondition(content.contains("private func automaticWatchPullDelay(reason: String) -> TimeInterval"),
                     "Automatic watch pull should route launch timing through an explicit delay policy")
        precondition(content.contains(#"case "appear", "active":"#),
                     "Opening or returning to the app should use the fastest automatic pull path")
        precondition(content.contains("return 0.0"),
                     "Opening the iPhone app should request pull sync immediately; pull client guards duplicate starts")
        precondition(content.contains(#"case "bound":"#) && content.contains("return 0.50"),
                     "The first pull after binding can keep a short settle delay")
        precondition(!content.contains("delay=1.6") && !content.contains("+ 1.6"),
                     "Automatic pull should not keep the old 1.6s launch delay")
        precondition(content.contains(#"syncNow(reason: "auto_\(reason)")"#),
                     "Automatic pull should still call the pull client with a reasoned log tag")

        print("auto_pull_latency_contract_smoke passed")
    }
}
