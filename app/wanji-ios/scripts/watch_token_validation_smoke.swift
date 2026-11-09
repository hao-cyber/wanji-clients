import Foundation

@main
struct WatchTokenValidationSmoke {
    static func main() {
        assertInvalid("", contains: "不可用")
        assertInvalid("   ", contains: "不可用")
        assertInvalid("ABCDE", contains: "过短")
        assertInvalid("ABC DEF", contains: "不可包含空格")
        assertInvalid("ABC\nDEF", contains: "不可包含空格")
        assertInvalid("ABC'DEF", contains: "格式不可用")
        assertInvalid("ABC\\DEF", contains: "格式不可用")
        assertInvalid("腕记TOKEN", contains: "格式不可用")
        assertInvalid(String(repeating: "A", count: 65), contains: "过长")

        assertValid("ABCDEF")
        assertValid(" ABCDEF ")
        assertValid("abc-DEF_123.45")
        assertValid("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

        precondition(AppSettings.normalizedWatchToken(" ABCDEF \n") == "ABCDEF",
                     "watch token should trim outer whitespace")

        print("watch_token_validation_smoke passed")
    }

    private static func assertValid(_ value: String) {
        precondition(AppSettings.watchTokenValidationMessage(value) == nil,
                     "expected valid token: \(value)")
    }

    private static func assertInvalid(_ value: String, contains expected: String) {
        guard let message = AppSettings.watchTokenValidationMessage(value),
              message.contains(expected) else {
            preconditionFailure("expected invalid token message containing \(expected), got \(String(describing: AppSettings.watchTokenValidationMessage(value)))")
        }
    }
}
