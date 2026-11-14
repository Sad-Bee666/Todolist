import Foundation
import Security

/// API Key 存储：优先钥匙串；钥匙串不可写时退化为 Application Support 下的 0600 文件。
enum SecretBox {
    private static let service = "com.sad-bee666.todolist"

    private static var fallbackDirectory: URL {
        TodoStore.defaultDirectory().appendingPathComponent("secrets", isDirectory: true)
    }

    private static func fallbackURL(account: String) -> URL {
        let safe = account.replacingOccurrences(of: "/", with: "_")
        return fallbackDirectory.appendingPathComponent(safe + ".key")
    }

    static func load(account: String) -> String? {
        if let key = keychainLoad(account: account), !key.isEmpty { return key }
        if let data = try? Data(contentsOf: fallbackURL(account: account)),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    static func save(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            delete(account: account)
            return
        }
        if keychainSave(trimmed, account: account) {
            try? FileManager.default.removeItem(at: fallbackURL(account: account))
            return
        }
        try? FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        let url = fallbackURL(account: account)
        try? Data(trimmed.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackURL(account: account))
    }

    private static func keychainLoad(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func keychainSave(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// 每个 provider 独立存一个 Key，切换预设不互相覆盖。
    static func account(for provider: AIProvider) -> String {
        "api-key-" + provider.rawValue
    }
}
