import Foundation

@main
struct LocalAudioPrivacyContractSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let content = try String(contentsOf: root.appendingPathComponent("Wanji/ContentView.swift"),
                                 encoding: .utf8)
        let store = try String(contentsOf: root.appendingPathComponent("Wanji/RecordingStore.swift"),
                               encoding: .utf8)

        precondition(content.contains("本机保护"),
                     "Storage privacy panel should still have concise local-protection copy when it appears")
        precondition(content.contains("本机加密保护，播放和上传期间保持可访问"),
                     "Storage privacy panel should explain protected long playback/upload access")
        precondition(content.contains(#"store.totalAudioBytes > 250 * 1024 * 1024"#),
                     "Routine protection copy should not occupy the home surface until storage is actionable")
        precondition(content.contains(#"storageAction != nil"#),
                     "Storage notice should still appear immediately while cleanup feedback is active")

        precondition(store.contains("FileProtectionType.completeUnlessOpen"),
                     "Recording files should keep iOS data protection without breaking already-open long playback/uploads")
        precondition(store.contains("try applyFileProtectionIfAvailable(to: root)"),
                     "Recording directory should be protected")
        precondition(store.contains("try applyFileProtectionIfAvailable(to: manifestURL)"),
                     "Recording manifest should be protected")
        precondition(store.contains("try applyFileProtectionIfAvailable(to: dest)"),
                     "Imported and watch-received audio files should be protected")
        precondition(store.contains("protectRetainedAudioFiles()"),
                     "Retained audio should be re-protected after loading old manifests")

        print("local_audio_privacy_contract_smoke passed")
    }
}
