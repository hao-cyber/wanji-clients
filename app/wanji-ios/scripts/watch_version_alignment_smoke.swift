import Foundation

@main
struct WatchVersionAlignmentSmoke {
    static func main() throws {
        let appRoot = try findAppRoot()

        let iosInfo = try String(contentsOf: appRoot.appendingPathComponent("wanji-ios/Info.plist"),
                                 encoding: .utf8)
        let project = try String(contentsOf: appRoot.appendingPathComponent("wanji-ios/project.yml"),
                                 encoding: .utf8)
        let wanjiApp = try String(contentsOf: appRoot.appendingPathComponent("wanji-ios/Wanji/WanjiApp.swift"),
                                  encoding: .utf8)

        let iosBuild = try capture(#"<key>CFBundleVersion</key>\s*<string>([^<]+)</string>"#,
                                   in: iosInfo,
                                   label: "iOS CFBundleVersion")
        let projectBuild = try capture(#"CFBundleVersion:\s*"([^"]+)""#,
                                       in: project,
                                       label: "project CFBundleVersion")

        precondition(Int(iosBuild) != nil && Int(iosBuild)! > 0,
                     "iOS CFBundleVersion should be a positive integer, got \(iosBuild)")
        precondition(projectBuild == iosBuild,
                     "project.yml CFBundleVersion should match Info.plist, got \(projectBuild) vs \(iosBuild)")
        precondition(wanjiApp.contains(#"Bundle.main.infoDictionary?["CFBundleVersion"]"#),
                     "WanjiApp debug log should read CFBundleVersion dynamically")
        precondition(!wanjiApp.contains(#"build=wanji-v"#),
                     "WanjiApp debug log should not hard-code a stale build tag")

        print("watch_version_alignment_smoke passed")
    }

    private static func findAppRoot() throws -> URL {
        var cursor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("wanji-ios/Info.plist")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        preconditionFailure("missing app root containing wanji-ios/Info.plist")
    }

    private static func capture(_ pattern: String, in text: String, label: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captureRange = Range(match.range(at: 1), in: text) else {
            preconditionFailure("missing \(label)")
        }
        return String(text[captureRange])
    }
}
