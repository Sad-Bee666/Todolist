import Foundation
import CoreGraphics

enum TodoSource: String, Codable, CaseIterable {
    case manual, screenshot, ai, qq, wechat

    var label: String {
        switch self {
        case .manual: return "手动"
        case .screenshot: return "截图"
        case .ai: return "AI"
        case .qq: return "QQ"
        case .wechat: return "微信"
        }
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var deadline: Date?
    var notes: String
    var isDone: Bool
    var createdAt: Date
    var updatedAt: Date
    var source: TodoSource

    init(id: UUID = UUID(),
         title: String,
         deadline: Date? = nil,
         notes: String = "",
         isDone: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         source: TodoSource = .manual) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.notes = notes
        self.isDone = isDone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
    }

    var isOverdue: Bool {
        guard let deadline, !isDone else { return false }
        return deadline < Date()
    }
}

struct ParsedTodo: Codable, Equatable {
    var title: String
    var deadline: Date?
    var note: String

    init(title: String, deadline: Date? = nil, note: String = "") {
        self.title = title
        self.deadline = deadline
        self.note = note
    }
}

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case deepseek, openai, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .custom: return "自定义 (OpenAI 兼容)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .custom: return ""
        }
    }
}

struct AIConfig: Codable, Equatable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var timeout: TimeInterval

    init(provider: AIProvider = .deepseek,
         baseURL: String = AIProvider.deepseek.defaultBaseURL,
         model: String = AIProvider.deepseek.defaultModel,
         timeout: TimeInterval = 60) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    /// 归一化到 <base>/chat/completions，base 允许带或不带 /v1。
    func chatCompletionsURL() -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        return URL(string: base + "/chat/completions")
    }

    var isRoutable: Bool {
        chatCompletionsURL() != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// ⌃⌥T
    static let standard = HotKeySpec(keyCode: 17, carbonModifiers: 0x1000 | 0x0800, display: "⌃⌥T")
}

struct AppSettings: Codable, Equatable {
    var ai: AIConfig
    var hotkey: HotKeySpec
    var hoverOpensPanel: Bool
    var hoverCloseDelay: Double

    init(ai: AIConfig = AIConfig(),
         hotkey: HotKeySpec = .standard,
         hoverOpensPanel: Bool = true,
         hoverCloseDelay: Double = 0.35) {
        self.ai = ai
        self.hotkey = hotkey
        self.hoverOpensPanel = hoverOpensPanel
        self.hoverCloseDelay = hoverCloseDelay
    }
}

enum TodoServiceError: LocalizedError {
    case notConfigured(String)
    case network(String)
    case decode(String)
    case captureCancelled
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): return "尚未配置：\(detail)"
        case .network(let detail): return "网络请求失败：\(detail)"
        case .decode(let detail): return "响应解析失败：\(detail)"
        case .captureCancelled: return "已取消截图"
        case .ocrFailed(let detail): return "识别失败：\(detail)"
        }
    }
}

protocol AIServicing: AnyObject {
    func extractTodos(from text: String, now: Date, config: AIConfig, apiKey: String) async throws -> [ParsedTodo]
}

protocol OCRServicing: AnyObject {
    func captureRegionImage() async throws -> CGImage
    func recognizeText(in image: CGImage) async throws -> String
}
