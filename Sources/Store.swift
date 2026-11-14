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
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func applyProviderDefaults(_ provider: AIProvider) {
        var ai = settings.ai
        ai.provider = provider
        ai.baseURL = provider.defaultBaseURL
        ai.model = provider.defaultModel
        settings.ai = ai
    }
}
