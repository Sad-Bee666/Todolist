import Foundation
import Combine

final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    @Published private(set) var items: [TodoItem] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["TODOLIST_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Todolist", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let dir = directory ?? TodoStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("todos.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        do {
            items = try decoder.decode([TodoItem].self, from: data)
        } catch {
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            items = []
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func add(_ item: TodoItem) -> TodoItem {
        items.append(item)
        persist()
        return item
    }

    @discardableResult
    func add(title: String, deadline: Date? = nil, notes: String = "", source: TodoSource = .manual) -> TodoItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return add(TodoItem(title: trimmed, deadline: deadline, notes: notes, source: source))
    }

    @discardableResult
    func addParsed(_ parsed: [ParsedTodo], source: TodoSource) -> Int {
        var added = 0
        for todo in parsed {
            let trimmed = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            items.append(TodoItem(title: trimmed, deadline: todo.deadline, notes: todo.note, source: source))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func update(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var copy = item
        copy.updatedAt = Date()
        items[index] = copy
        persist()
    }

    func toggleDone(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        items[index].updatedAt = Date()
        persist()
    }

    func setDeadline(id: UUID, deadline: Date?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deadline = deadline
        items[index].updatedAt = Date()
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearCompleted() {
        items.removeAll { $0.isDone }
        persist()
    }

    /// 未完成按截止时间升序（无截止时间置底），已完成整体沉底。
    func sortedItems() -> [TodoItem] {
        let pending = items.filter { !$0.isDone }.sorted { lhs, rhs in
            switch (lhs.deadline, rhs.deadline) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.createdAt < rhs.createdAt
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                return lhs.createdAt < rhs.createdAt
            }
        }
        let done = items.filter { $0.isDone }.sorted { $0.updatedAt > $1.updatedAt }
        return pending + done
    }

    func pendingCount() -> Int { items.filter { !$0.isDone }.count }

    func overdueCount() -> Int { items.filter { $0.isOverdue }.count }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var settings: AppSettings {
        didSet { persist() }
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let dir = directory ?? TodoStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("settings.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            let fixed = SettingsStore.sanitized(decoded)
            self.settings = fixed
            if fixed != decoded, let repaired = try? encoder.encode(fixed) {
                try? repaired.write(to: fileURL, options: .atomic)
            }
        } else {
            self.settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 空的 Base URL / 模型名无法路由；逐份配置归一，并保证「当前配置」有效。
    static func sanitized(_ value: AppSettings) -> AppSettings {
        var fixed = value
        if fixed.profiles.isEmpty {
            fixed.profiles = [APIProfile(name: AIProvider.deepseek.displayName)]
        }
        for index in fixed.profiles.indices {
            var profile = fixed.profiles[index]
            if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
                profile.name = profile.provider.displayName
            }
            // 只补缺失字段：已配置的提供商与地址绝不能被覆盖
            if profile.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                profile.baseURL = profile.provider.defaultBaseURL
            }
            if profile.model.trimmingCharacters(in: .whitespaces).isEmpty {
                profile.model = profile.models.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    ?? profile.provider.defaultModel
            }
            var list = profile.models.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if list.isEmpty { list = [profile.model] }
            if !list.contains(profile.model) { list.insert(profile.model, at: 0) }
            if list.count > 12 { list = Array(list.prefix(12)) }
            profile.models = list
            fixed.profiles[index] = profile
        }
        let ids = Set(fixed.profiles.map { $0.id })
        if fixed.activeProfileID == nil || !ids.contains(fixed.activeProfileID!) {
            fixed.activeProfileID = fixed.profiles.first?.id
        }
        return fixed
    }

}
