import Foundation

/// API Key 存储：0600 权限的本地文件。
///
/// 刻意不用钥匙串：ad-hoc 签名的应用每次重新构建签名都会变，钥匙串会弹授权框；
/// 若无人应答，SecItemCopyMatching 会把主线程卡死，应用连菜单栏图标都出不来。
enum SecretBox {
    private static var directory: URL {
        TodoStore.defaultDirectory().appendingPathComponent("secrets", isDirectory: true)
    }

    private static func url(account: String) -> URL {
        let safe = account.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".key")
    }

    static func load(account: String) -> String? {
        guard let data = try? Data(contentsOf: url(account: account)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account: account)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(account: account)
        try? Data(trimmed.utf8).write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: url(account: account))
    }

    /// 每个 API 配置独立存一个 Key。
    static func account(forProfile id: UUID) -> String {
        "api-key-" + id.uuidString
    }

    /// 旧版按 provider 存的账户名，仅用于迁移。
    static func account(for provider: AIProvider) -> String {
        "api-key-" + provider.rawValue
    }

    /// 把旧版 provider 账户下的 Key 搬到配置账户；搬完删除旧文件，避免被新建配置误继承。
    @discardableResult
    static func migrateKeyIfNeeded(from provider: AIProvider, toProfile id: UUID) -> Bool {
        let target = account(forProfile: id)
        let legacyAccount = account(for: provider)
        guard load(account: target) == nil,
              let legacy = load(account: legacyAccount), !legacy.isEmpty else { return false }
        save(legacy, account: target)
        delete(account: legacyAccount)
        return true
    }
}
