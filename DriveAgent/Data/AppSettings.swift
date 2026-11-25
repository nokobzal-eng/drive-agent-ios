import Foundation
import Security

struct AppSettings {
    var apiKey: String
    var model: String
    var assistantName: String
    var ownerName: String
}

/// Everything personal lives here, on the device. Nothing about the owner is built into the app.
enum SettingsStore {
    static let defaultModel = "claude-sonnet-5-5"
    static let defaultAssistantName = "שלומי"

    private static let modelKey = "model"
    private static let assistantKey = "assistantName"
    private static let ownerKey = "ownerName"
    private static let keychainAccount = "anthropic_api_key"

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        return AppSettings(
            apiKey: readKey(),
            model: defaults.string(forKey: modelKey) ?? defaultModel,
            assistantName: defaults.string(forKey: assistantKey) ?? defaultAssistantName,
            ownerName: defaults.string(forKey: ownerKey) ?? ""
        )
    }

    static func save(_ settings: AppSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.model, forKey: modelKey)
        defaults.set(settings.assistantName, forKey: assistantKey)
        defaults.set(settings.ownerName, forKey: ownerKey)
        writeKey(settings.apiKey)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: keychainAccount]
    }

    private static func readKey() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeKey(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !key.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        // Readable while the phone is locked, which is the normal state while driving.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
