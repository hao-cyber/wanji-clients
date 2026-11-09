import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("app/wanji-ios/Wanji/ContentView.swift")
let text = try String(contentsOf: source, encoding: .utf8)

precondition(text.contains("import Network"),
             "home should use Network framework for visible offline/weak-network state")
precondition(text.contains("final class NetworkStatusMonitor: ObservableObject"),
             "network state should be observable instead of inferred from failed uploads")
precondition(text.contains("@StateObject private var networkMonitor = NetworkStatusMonitor()"),
             "home should own a network monitor for generation actions")
precondition(text.contains("private var canStartRemoteGeneration: Bool"),
             "remote generation should be gated by backend and network readiness")
precondition(text.contains("网络不可用，录音会留在本机；联网后可继续生成完整转写和纪要。"),
             "offline state should tell users recordings remain local and generation can be retried")
precondition(text.contains("当前是低数据模式，长录音转写可能变慢"),
             "constrained network should set expectations for long recordings")
precondition(text.contains("NetworkStatusRow(text: networkWarningText"),
             "home generation panels should show inline network feedback")
precondition(text.contains("if !networkReady { return \"离线\" }"),
             "row generation buttons should show offline state before users tap")
precondition(text.contains("guard networkMonitor.canReachRemoteBackend else"),
             "bulk generation should not enqueue remote jobs while offline")

print("network_generation_feedback_smoke passed")
