import Foundation

@main
struct ImportPartialFailureSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-import-partial-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanji-import-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let goodURL = sourceDir.appendingPathComponent("manual.m4a")
        let missingURL = sourceDir.appendingPathComponent("missing.m4a")
        let tinyURL = sourceDir.appendingPathComponent("tiny.m4a")
        let folderURL = sourceDir.appendingPathComponent("folder.m4a", isDirectory: true)
        try Data(repeating: 4, count: 4096).write(to: goodURL)
        try Data(repeating: 5, count: 64).write(to: tinyURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let store = await MainActor.run {
            RecordingStore(rootURL: root, backendStatusProvider: { .ready })
        }

        let result = await store.importFiles([goodURL, missingURL, tinyURL, folderURL])
        precondition(result.importedCount == 1, "expected one imported file, got \(result.importedCount)")
        precondition(result.failedCount == 3, "expected three failed files, got \(result.failedCount)")

        let snapshot = await MainActor.run {
            (
                items: store.items,
                error: store.errorText,
                importing: store.importing
            )
        }
        precondition(snapshot.items.count == 1, "partial import should keep successful item")
        precondition(snapshot.items.first?.originalName == "manual.m4a", "expected original filename to be preserved")
        precondition(snapshot.error?.contains("已导入 1 条") == true, "expected partial failure error text")
        precondition(snapshot.importing == false, "importing flag should clear after import")
        let retainedAudio = try FileManager.default.contentsOfDirectory(at: root,
                                                                        includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "m4a" }
        precondition(retainedAudio.count == 1, "invalid imports should not leave orphan audio files")

        let reloaded = await MainActor.run {
            RecordingStore(rootURL: root, backendStatusProvider: { .ready })
        }
        await MainActor.run { reloaded.load() }
        let reloadedItems = await MainActor.run { reloaded.items }
        precondition(reloadedItems.count == 1, "successful partial import should be persisted")

        print("import_partial_failure_smoke passed")
    }
}
