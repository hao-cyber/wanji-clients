import Foundation

@main
struct BackendConfigurationPreviewSmoke {
    static func main() {
        let existingServer = UserDefaults.standard.string(forKey: AppSettings.serverURLKey)
        let existingToken = KeychainStore.token()
        let url = BackendConfigurationLink.make(serverURL: "https://untrusted.example.com",
                                                 token: "synthetic-test-token")!
        guard case .ready(let candidate) = BackendConfigurationLink.preview(url) else {
            preconditionFailure("valid configuration should be available for review")
        }
        precondition(candidate.serverURL == "https://untrusted.example.com")
        precondition(UserDefaults.standard.string(forKey: AppSettings.serverURLKey) == existingServer,
                     "opening a configuration link must not change the upload destination")
        precondition(KeychainStore.token() == existingToken,
                     "previewing a configuration link must not replace credentials")
        let invalid = URL(string: "wanji://configure?server=http%3A%2F%2Funtrusted.example.com&token=test")!
        guard case .rejected(.invalid) = BackendConfigurationLink.preview(invalid) else {
            preconditionFailure("insecure destinations must be rejected before confirmation")
        }
        print("backend_configuration_preview_smoke passed")
    }
}
