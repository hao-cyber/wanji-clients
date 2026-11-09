import Foundation

@main
struct WatchControlFailureRequeueSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let pullClient = try String(contentsOf: root.appendingPathComponent("Wanji/BluetoothWatchPullClient.swift"),
                                    encoding: .utf8)

        precondition(pullClient.contains("private var controlFailureQueueRetries = 0") &&
                     pullClient.contains("private var controlFailureItemID: String?") &&
                     pullClient.contains("private let maxControlFailureQueueRetries = 1"),
                     "Control write failures should have a bounded per-item queue reread policy")
        precondition(pullClient.contains("private func retryQueueAfterControlFailure() -> Bool") &&
                     pullClient.contains("controlFailureItemID != failedID") &&
                     pullClient.contains("controlFailureQueueRetries < maxControlFailureQueueRetries"),
                     "Control failure retry should be tied to the failed recording id")
        precondition(pullClient.contains(#"setStatus("跳过不可用录音，继续查找", severity: .processing)"#) &&
                     pullClient.contains(#"scheduleQueueRead(from: target, after: 0.25, reason: "control-failure-skip")"#),
                     "A recoverable control failure should immediately reread the queue for the next item")
        precondition(pullClient.contains("if retryQueueAfterControlFailure() {\n                    return\n                }\n                fail(\"请求手表录音失败\")"),
                     "The pull client should only fail after the bounded queue reread path is exhausted")

        print("watch_control_failure_requeue_smoke passed")
    }
}
