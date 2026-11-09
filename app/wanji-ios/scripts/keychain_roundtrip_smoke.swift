import Foundation

@main
struct KeychainRoundtripSmoke {
    static func main() {
        let original = KeychainStore.token()
        defer {
            if let original {
                precondition(KeychainStore.setToken(original), "failed to restore original token")
            } else {
                precondition(KeychainStore.clearToken(), "failed to restore empty token")
            }
        }

        precondition(KeychainStore.clearToken(), "clear should succeed even when token is absent")
        precondition(KeychainStore.token() == nil, "token should be empty after clear")

        precondition(KeychainStore.setToken("first-token"), "initial token save should succeed")
        precondition(KeychainStore.token() == "first-token", "initial token should roundtrip")

        precondition(KeychainStore.setToken("second-token"), "token update should succeed")
        precondition(KeychainStore.token() == "second-token", "updated token should roundtrip")

        precondition(KeychainStore.clearToken(), "token clear should succeed")
        precondition(KeychainStore.token() == nil, "token should be empty after final clear")

        print("keychain_roundtrip_smoke passed")
    }
}
