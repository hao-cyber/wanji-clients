import Foundation

enum AppSettings {
    // Recording and Bluetooth sync work without a remote service.
    static let defaultServerURL = ""
    static let serverURLKey = "server_url"
    static let watchTokenKey = "watch_connection_token"
    static let watchBindingConfirmedKey = "watch_binding_confirmed"
    static let legacyWatchTokenKey = "watch_receiver_token"
    static let autoDeleteAudioAfterNotesKey = "auto_delete_audio_after_notes"
    static let bleEndpoint = "ble://wanji"
    static let bleServiceUUID = "7E1A1000-AD67-4F51-98E4-65C8E60B9C01"
    static let bleWriteCharacteristicUUID = "7E1A1001-AD67-4F51-98E4-65C8E60B9C01"
    static let watchSyncServiceUUID = "7E1A2000-AD67-4F51-98E4-65C8E60B9C01"
    static let watchSyncCommandCharacteristicUUID = "7E1A2001-AD67-4F51-98E4-65C8E60B9C01"
    static let watchPullServiceUUID = "7E1A4400-AD67-4F51-98E4-65C8E60B9C01"
    static let watchPullQueueCharacteristicUUID = "7E1A4401-AD67-4F51-98E4-65C8E60B9C01"
    static let watchPullControlCharacteristicUUID = "7E1A4402-AD67-4F51-98E4-65C8E60B9C01"
    static let watchPullDataCharacteristicUUID = "7E1A4403-AD67-4F51-98E4-65C8E60B9C01"
    static let watchPullAckCharacteristicUUID = "7E1A4404-AD67-4F51-98E4-65C8E60B9C01"

    static func normalizedWatchToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func watchTokenValidationMessage(_ value: String) -> String? {
        let token = normalizedWatchToken(value)
        if token.isEmpty {
            return "手表绑定凭证不可用。"
        }
        if token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "手表绑定凭证不可包含空格或换行。"
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        if token.rangeOfCharacter(from: allowed.inverted) != nil {
            return "手表绑定凭证格式不可用。"
        }
        if token.count < 6 {
            return "手表绑定凭证过短。"
        }
        if token.count > 64 {
            return "手表绑定凭证过长。"
        }
        return nil
    }
}
