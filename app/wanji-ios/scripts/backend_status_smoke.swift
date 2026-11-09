import Foundation

@main
struct BackendStatusSmoke {
    static func main() {
        assertStatus(AppSettings.defaultServerURL, "", .missingServer)
        assertStatus("", "", .missingServer)
        assertStatus("https://api.example.com", "", .missingToken)
        assertStatus("api.example.com", "token", .invalidURL)
        assertStatus("http://api.example.com", "token", .insecureURL)
        assertStatus("http://localhost:8000", "token", .ready)
        assertStatus("http://127.0.0.1:8000", "token", .ready)
        assertStatus("https://api.example.com/", "token", .ready)

        print("backend_status_smoke passed")
    }

    private static func assertStatus(_ serverURL: String,
                                     _ token: String,
                                     _ expected: MeetingNotesAPI.BackendStatus) {
        let actual = MeetingNotesAPI.backendStatus(serverURL: serverURL, token: token)
        precondition(actual == expected,
                     "expected \(expected) for \(serverURL), got \(actual)")
    }
}
