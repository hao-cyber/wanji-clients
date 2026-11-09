import Foundation

@main
struct WatchMultiItemCompletionSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let ios = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                             encoding: .utf8)

        precondition(ios.contains("private var completedItemsThisSync = 0") &&
                     ios.contains("completedItemsThisSync = 0") &&
                     ios.contains("self.completedItemsThisSync += 1"),
                     "A foreground pull session should count successfully saved watch recordings")
        precondition(ios.contains(#""已同步 \(completedItemsThisSync) 条手表录音""#) &&
                     ios.contains(#""手表没有待同步录音""#) &&
                     ios.contains("completedItemsThisSync > 0"),
                     "Empty queue after ACK-continuation should summarize how many recordings were received")
        precondition(ios.contains("setStatus(\"检查下一条手表录音\", severity: .processing)") &&
                     ios.contains("scheduleQueueRead(from: target, after: ackContinueQueueReadDelay, reason: \"ack-continue\")"),
                     "ACK success should continue reading the same watch queue for additional recordings")

        print("watch_multi_item_completion_smoke passed")
    }
}
